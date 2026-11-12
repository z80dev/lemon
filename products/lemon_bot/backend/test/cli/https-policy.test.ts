import { describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { baseBotMcpTemplate } from '../../src/core/bots';
import { runHttpsPolicyCli, type HttpsPolicyCliDependencies } from '../../src/cli/https-policy';

const origin = 'https://lemon.private-tailnet.ts.net';
const unrelated = 'https://unrelated.private-tailnet.ts.net';
const args = ['--origin', origin, '--json'];
const expected = { origin, allowedOrigins: [origin], approvedPrivateOrigins: [origin] };
function fixture(config: unknown = { version: 1, approvedPrivateMcpOrigins: [origin] }) {
  const stdout: string[] = []; const stderr: string[] = []; const paths: string[] = []; let templates = 0;
  const deps: HttpsPolicyCliDependencies = {
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
    stdout(value) { stdout.push(value); }, stderr(value) { stderr.push(value); },
  };
  return { deps, stdout, stderr, paths, templates: () => templates, result: () => JSON.parse(stdout.join('')) };
}

describe('internal HTTPS first-party MCP policy command', () => {
  test('uses the actual remote template and projects only the exact approved first-party origin', async () => {
    const f = fixture({ version: 1, approvedPrivateMcpOrigins: [unrelated, origin], serverSecrets: { private: { kind: 'env', name: 'PRIVATE_SECRET_SOURCE' } }, namedAgentOperatorUserId: 'PRIVATE_USER' });
    expect(await runHttpsPolicyCli(args, f.deps)).toBe(0);
    expect(f.result()).toEqual(expected);
    expect(f.paths).toEqual(['/private-home/.lemon/lemon_bot/config.json']);
    expect(f.templates()).toBe(1); expect(f.stderr).toHaveLength(0);
    expect(f.stdout.join('')).not.toContain('PRIVATE_');
    expect(f.stdout.join('')).not.toContain(unrelated);
    expect(f.stdout.join('').length).toBeLessThan(8192);
  });
  test('canonicalizes equivalent requested origins before comparing the configured public URL', async () => {
    const f = fixture();
    expect(await runHttpsPolicyCli(['--json', '--origin', 'https://LEMON.PRIVATE-TAILNET.TS.NET:443/'], f.deps)).toBe(0);
    expect(f.result()).toEqual(expected);
  });
  test('honors the explicit operator configuration file without touching other private state', async () => {
    const f = fixture(); f.deps.env.LEMON_BOT_CONFIG_FILE = '/private-config/operator.json';
    expect(await runHttpsPolicyCli(args, f.deps)).toBe(0);
    expect(f.paths).toEqual(['/private-config/operator.json']);
  });
  for (const approvedPrivateMcpOrigins of [[], [unrelated]]) test(`does not approve the first-party origin from ${JSON.stringify(approvedPrivateMcpOrigins)}`, async () => {
    const f = fixture({ version: 1, approvedPrivateMcpOrigins });
    expect(await runHttpsPolicyCli(args, f.deps)).toBe(1);
    expect(f.templates()).toBe(1); expect(f.stdout).toHaveLength(0);
    expect(f.stderr.join('')).not.toContain(unrelated);
  });
  test('cannot request an unrelated origin even when it is approved', async () => {
    const f = fixture({ version: 1, approvedPrivateMcpOrigins: [origin, unrelated] });
    expect(await runHttpsPolicyCli(['--origin', unrelated, '--json'], f.deps)).toBe(1);
    expect(f.stdout).toHaveLength(0); expect(f.templates()).toBe(0);
  });
  for (const value of ['http://127.0.0.1:4100', `${origin}/mcp`, `${origin}?secret=PRIVATE_QUERY`, `${origin}#PRIVATE_FRAGMENT`, 'https://PRIVATE_USER:PRIVATE_PASSWORD@lemon.private-tailnet.ts.net', 'PRIVATE_INVALID', `https://${'x'.repeat(2100)}.ts.net`, `${origin}\n`]) test(`rejects malformed origin ${JSON.stringify(value.slice(0, 100))}`, async () => {
    const f = fixture();
    expect(await runHttpsPolicyCli(['--origin', value, '--json'], f.deps)).toBe(1);
    expect(f.paths).toHaveLength(0); expect(f.stdout).toHaveLength(0); expect(f.stderr.join('')).not.toContain('PRIVATE_');
  });
  for (const config of [{ version: 2 }, { version: 1, unexpected: 'PRIVATE_FIELD' }, { version: 1, approvedPrivateMcpOrigins: [`${origin}/mcp`] }, { version: 1, approvedPrivateMcpOrigins: [origin], providerSpendSources: [{ providerAccount: 'private', apiBaseUrl: origin, secretRef: 'PRIVATE_MISSING_SECRET' }] }]) test(`uses normal operator configuration validation ${JSON.stringify(config)}`, async () => {
    const f = fixture(config);
    expect(await runHttpsPolicyCli(args, f.deps)).toBe(1);
    expect(f.stdout).toHaveLength(0); expect(f.templates()).toBe(0); expect(f.stderr.join('')).not.toContain('PRIVATE_');
  });
  test('does not expose parser, file or template errors', async () => {
    for (const failure of ['read', 'json', 'template']) {
      const f = fixture();
      if (failure === 'read') f.deps.readConfig = async () => { throw new Error('PRIVATE_PATH PRIVATE_TOKEN'); };
      if (failure === 'json') f.deps.readConfig = async () => '{ PRIVATE_JSON';
      if (failure === 'template') f.deps.template = () => { throw new Error('PRIVATE_TEMPLATE'); };
      expect(await runHttpsPolicyCli(args, f.deps)).toBe(1);
      expect(f.stdout).toHaveLength(0); expect(f.stderr.join('')).not.toContain('PRIVATE_');
    }
  });
  for (const invalid of [[], ['--json'], ['--origin', origin], [...args, '--json'], [...args, '--origin', origin], ['--origin'], [...args, '--token', 'PRIVATE_TOKEN']]) test(`rejects unsupported argv ${JSON.stringify(invalid)}`, async () => {
    const f = fixture();
    expect(await runHttpsPolicyCli(invalid, f.deps)).toBe(2);
    expect(f.paths).toHaveLength(0); expect(f.stdout).toHaveLength(0); expect(f.stderr.join('')).not.toContain('PRIVATE_');
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
      expect(await runHttpsPolicyCli(args, f.deps)).toBe(0);
      expect(f.result()).toEqual(expected);
      expect(await readFile(path, 'utf8')).toBe(config);
      expect((await stat(path)).mtimeMs).toBe(before.mtimeMs);
      expect((await stat(path)).mode).toBe(before.mode);
      expect(await readdir(dataDir)).toEqual(['config.json']);
      expect(f.stdout.join('') + f.stderr.join('')).not.toContain('PRIVATE_');
    } finally { await rm(dataDir, { recursive: true, force: true }); }
  });
  test('missing config fails without creating config, keys, database or data directory', async () => {
    const root = await mkdtemp(join(tmpdir(), 'bot-https-policy-missing-'));
    try {
      const f = fixture(); f.deps.env.LEMON_BOT_DATA_DIR = join(root, 'missing'); f.deps.readConfig = path => readFile(path, 'utf8');
      expect(await runHttpsPolicyCli(args, f.deps)).toBe(1);
      expect(f.stdout).toHaveLength(0); expect(await readdir(root)).toEqual([]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
  test('lazy CLI dispatch emits the exact policy without initializing backend state', async () => {
    const dataDir = await mkdtemp(join(tmpdir(), 'bot-https-policy-cli-'));
    try {
      await writeFile(join(dataDir, 'operator.json'), JSON.stringify({ version: 1, approvedPrivateMcpOrigins: [origin] }));
      const cli = new URL('../../src/cli.ts', import.meta.url).pathname;
      const child = Bun.spawn([process.execPath, cli, 'https-policy', ...args], { env: { HOME: dataDir, PATH: '/usr/bin:/bin', BUN_RUNTIME_TRANSPILER_CACHE_PATH: '0', LEMON_BOT_DATA_DIR: join(dataDir, 'absent'), LEMON_BOT_CONFIG_FILE: join(dataDir, 'operator.json'), LEMON_BOT_PUBLIC_URL: origin }, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(0); expect(JSON.parse(stdout)).toEqual(expected); expect(stderr).toBe('');
      expect(await readdir(dataDir)).toEqual(['operator.json']);
    } finally { await rm(dataDir, { recursive: true, force: true }); }
  });
});
