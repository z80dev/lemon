import { describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { baseBotMcpTemplate } from '../../src/core/bots';
import { firstPartyHttpsPolicy, type HttpsPolicyDependencies } from '../../src/cli/https-policy';

const origin = 'https://lemon.private-tailnet.ts.net';
const unrelated = 'https://unrelated.private-tailnet.ts.net';
const expected = { origin, allowedOrigins: [origin], approvedPrivateOrigins: [origin] };
function fixture(config: unknown = { version: 1, approvedPrivateMcpOrigins: [origin] }) {
  const paths: string[] = []; let templates = 0;
  const deps: HttpsPolicyDependencies = {
    env: { HOME: '/private-home', LEMON_BOT_PUBLIC_URL: origin, LEMON_BOT_OPERATOR_TOKEN: 'PRIVATE_OPERATOR', LEMON_BOT_ENCRYPTION_KEY: 'PRIVATE_KEY' },
    async readConfig(path) { paths.push(path); return JSON.stringify(config); },
    template(services, machine) {
      templates++;
      expect(services.config.publicUrl).toBe(origin);
      expect(machine.link?.kind).toBe('direct');
      expect(machine.nodeId).toBeNull();
      const template = baseBotMcpTemplate(services, machine);
      return { ...template, headers: { Authorization: 'PRIVATE_HEADER' } };
    },
  };
  return { deps, paths, templates: () => templates };
}

describe('first-party HTTPS MCP policy', () => {
  test('uses the actual remote template and projects only the exact approved first-party origin', async () => {
    const f = fixture({ version: 1, approvedPrivateMcpOrigins: [unrelated, origin], serverSecrets: { private: { kind: 'env', name: 'PRIVATE_SECRET_SOURCE' } }, namedAgentOperatorUserId: 'PRIVATE_USER' });
    const policy = await firstPartyHttpsPolicy(origin, f.deps);
    expect(policy).toEqual(expected);
    expect(f.paths).toEqual(['/private-home/.lemon/lemon_bot/config.json']);
    expect(f.templates()).toBe(1);
    expect(JSON.stringify(policy)).not.toContain('PRIVATE_');
  });
  test('canonicalizes equivalent requested origins before comparing the configured public URL', async () => {
    expect(await firstPartyHttpsPolicy('https://LEMON.PRIVATE-TAILNET.TS.NET:443/', fixture().deps)).toEqual(expected);
  });
  test('honors the explicit operator configuration file without touching other private state', async () => {
    const f = fixture(); f.deps.env.LEMON_BOT_CONFIG_FILE = '/private-config/operator.json';
    expect(await firstPartyHttpsPolicy(origin, f.deps)).toEqual(expected);
    expect(f.paths).toEqual(['/private-config/operator.json']);
  });
  for (const approvedPrivateMcpOrigins of [[], [unrelated]]) test(`does not approve the first-party origin from ${JSON.stringify(approvedPrivateMcpOrigins)}`, async () => {
    const f = fixture({ version: 1, approvedPrivateMcpOrigins });
    expect(await firstPartyHttpsPolicy(origin, f.deps)).toBeNull();
    expect(f.templates()).toBe(1);
  });
  test('cannot request an unrelated origin even when it is approved', async () => {
    const f = fixture({ version: 1, approvedPrivateMcpOrigins: [origin, unrelated] });
    expect(await firstPartyHttpsPolicy(unrelated, f.deps)).toBeNull();
    expect(f.templates()).toBe(0);
  });
  for (const value of ['http://127.0.0.1:4100', `${origin}/mcp`, `${origin}?secret=PRIVATE_QUERY`, `${origin}#PRIVATE_FRAGMENT`, 'https://PRIVATE_USER:PRIVATE_PASSWORD@lemon.private-tailnet.ts.net', 'PRIVATE_INVALID', `https://${'x'.repeat(2100)}.ts.net`, `${origin}\n`]) test(`rejects malformed origin ${JSON.stringify(value.slice(0, 100))}`, async () => {
    const f = fixture();
    expect(await firstPartyHttpsPolicy(value, f.deps)).toBeNull();
    expect(f.paths).toHaveLength(0);
  });
  for (const config of [{ version: 2 }, { version: 1, unexpected: 'PRIVATE_FIELD' }, { version: 1, approvedPrivateMcpOrigins: [`${origin}/mcp`] }, { version: 1, approvedPrivateMcpOrigins: [origin], providerSpendSources: [{ providerAccount: 'private', apiBaseUrl: origin, secretRef: 'PRIVATE_MISSING_SECRET' }] }]) test(`uses normal operator configuration validation ${JSON.stringify(config)}`, async () => {
    const f = fixture(config);
    expect(await firstPartyHttpsPolicy(origin, f.deps)).toBeNull();
    expect(f.templates()).toBe(0);
  });
  test('parser, file and template errors are a refusal, not an exception', async () => {
    for (const failure of ['read', 'json', 'template']) {
      const f = fixture();
      if (failure === 'read') f.deps.readConfig = async () => { throw new Error('PRIVATE_PATH PRIVATE_TOKEN'); };
      if (failure === 'json') f.deps.readConfig = async () => '{ PRIVATE_JSON';
      if (failure === 'template') f.deps.template = () => { throw new Error('PRIVATE_TEMPLATE'); };
      expect(await firstPartyHttpsPolicy(origin, f.deps)).toBeNull();
    }
  });
});

describe('HTTPS policy existing configuration inspection', () => {
  test('reads real config with no database, keys, secret resolution or writes', async () => {
    const dataDir = await mkdtemp(join(tmpdir(), 'bot-https-policy-'));
    const path = join(dataDir, 'config.json');
    const config = JSON.stringify({ version: 1, approvedPrivateMcpOrigins: [unrelated, origin], serverSecrets: { private: { kind: 'file', path: '/PRIVATE_NONEXISTENT_SECRET' } } });
    try {
      await writeFile(path, config, { mode: 0o600 });
      const before = await stat(path);
      const f = fixture(); f.deps.env.LEMON_BOT_DATA_DIR = dataDir; f.deps.readConfig = path => readFile(path, 'utf8');
      expect(await firstPartyHttpsPolicy(origin, f.deps)).toEqual(expected);
      expect(await readFile(path, 'utf8')).toBe(config);
      expect((await stat(path)).mtimeMs).toBe(before.mtimeMs);
      expect((await stat(path)).mode).toBe(before.mode);
      expect(await readdir(dataDir)).toEqual(['config.json']);
    } finally { await rm(dataDir, { recursive: true, force: true }); }
  });
  test('missing config fails without creating config, keys, database or data directory', async () => {
    const root = await mkdtemp(join(tmpdir(), 'bot-https-policy-missing-'));
    try {
      const f = fixture(); f.deps.env.LEMON_BOT_DATA_DIR = join(root, 'missing'); f.deps.readConfig = path => readFile(path, 'utf8');
      expect(await firstPartyHttpsPolicy(origin, f.deps)).toBeNull();
      expect(await readdir(root)).toEqual([]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
});
