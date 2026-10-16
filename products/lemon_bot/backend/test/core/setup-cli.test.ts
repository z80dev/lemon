import { describe, expect, test } from 'bun:test';
import { runSetupCli } from '../../src/setup-cli';
import type { SetupCliDependencies } from '../../src/setup-cli';
import { Database } from 'bun:sqlite';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// All local state, terminal and transport below are trusted mocks; no Tailscale,
// controller, provider, actual proof issuance or controlling terminal is used.
function fixture(options: { configured?: boolean; origin?: string; descriptor?: Record<string, unknown>; terminalUnavailable?: boolean; response?: Response; transportError?: boolean } = {}) {
  const origin = options.origin ?? 'https://desktop.example.ts.net';
  let issued = 0; let opened = 0; let probes = 0;
  const stdout: string[] = []; const stderr: string[] = []; const terminal: string[] = [];
  const dependencies: SetupCliDependencies = {
    async readLocal() { return { origin, instanceId: 'local-instance', configured: options.configured ?? false, close() {},
      async issue() { issued++; return { code: 'MOCK-PRIVATE-PROOF', expiresAtMs: 300000 }; } }; },
    openTerminal() { opened++; if (options.terminalUnavailable) throw new Error('MOCK PRIVATE ERROR'); return { write(value) { terminal.push(value); }, close() {} }; },
    stdout(value) { stdout.push(value); }, stderr(value) { stderr.push(value); },
    fetch: (async (input, init) => {
      probes++;
      expect(String(input)).toBe(`${origin}/v1/setup`);
      expect(init?.redirect).toBe('manual'); expect(init?.credentials).toBe('omit');
      expect(new Headers(init?.headers).has('Authorization')).toBe(false);
      if (options.transportError) throw new Error('MOCK TLS PRIVATE ERROR');
      return options.response ?? Response.json({ product: 'lemon_bot', apiVersion: 1, instanceId: 'local-instance', version: '2026.10.1', publicUrl: origin,
        setupRequired: !options.configured, capabilities: { pairing: true }, ...options.descriptor });
    }) as typeof fetch,
  };
  return { dependencies, stdout, stderr, terminal, counts: () => ({ issued, opened, probes }) };
}

describe('owner setup CLI with trusted mocks', () => {
  test('proof is terminal-only; argv is nonsecret and unchanged; no provider checks', async () => {
    const f = fixture(); const args: string[] = [];
    expect(await runSetupCli(args, f.dependencies)).toBe(0);
    expect(args).toEqual([]); expect(f.stdout).toEqual(['https://desktop.example.ts.net\n']);
    expect(f.stderr).toEqual([]); expect(f.terminal.join('')).toContain('MOCK-PRIVATE-PROOF');
    expect(f.terminal.join('')).toContain('single use'); expect(f.counts()).toEqual({ issued: 1, opened: 1, probes: 1 });
  });
  test('terminal failure precedes proof issuance and hides unexpected errors', async () => {
    const f = fixture({ terminalUnavailable: true });
    expect(await runSetupCli([], f.dependencies)).toBe(1); expect(f.counts().issued).toBe(0);
    expect(f.stdout).toEqual([]); expect(f.stderr.join('')).not.toContain('PRIVATE');
  });
  for (const configured of [false, true]) test(`print-origin is proof-less and terminal-less configured=${configured}`, async () => {
    const f = fixture({ configured, terminalUnavailable: true });
    expect(await runSetupCli(['--print-origin'], f.dependencies)).toBe(0);
    expect(f.stdout).toEqual(['https://desktop.example.ts.net\n']); expect(f.stderr).toEqual([]);
    expect(f.counts()).toEqual({ issued: 0, opened: 0, probes: 1 });
  });
  test('configured workspace refuses proof without altering accounts/pairing', async () => {
    const f = fixture({ configured: true }); expect(await runSetupCli([], f.dependencies)).toBe(1);
    expect(f.counts().issued).toBe(0); expect(f.counts().opened).toBe(0);
  });
  for (const origin of ['http://desktop.example.ts.net', 'https://example.com', 'http://127.0.0.1:4080', 'https://desktop.example.ts.net/', 'https://user:secret@desktop.example.ts.net']) {
    test(`rejects invalid remote origin ${origin}`, async () => {
      const f = fixture({ origin }); expect(await runSetupCli(['--print-origin'], f.dependencies)).toBe(1);
      expect(f.stdout).toEqual([]); expect(f.counts().probes).toBe(0);
    });
  }
  test('preserves the exact configured tailnet HTTPS port', async () => {
    const f = fixture({ origin: 'https://desktop.example.ts.net:8449' });
    expect(await runSetupCli(['--print-origin'], f.dependencies)).toBe(0);
    expect(f.stdout).toEqual(['https://desktop.example.ts.net:8449\n']); expect(f.counts().issued).toBe(0);
  });
  for (const descriptor of [{ instanceId: 'wrong-instance' }, { product: 'wrong-service' }, { publicUrl: 'https://other.example.ts.net' }, { setupRequired: false }]) {
    test(`rejects mismatched fingerprint ${JSON.stringify(descriptor)}`, async () => {
      const f = fixture({ descriptor }); expect(await runSetupCli([], f.dependencies)).toBe(1);
      expect(f.counts().issued).toBe(0); expect(f.stdout).toEqual([]);
    });
  }
  test('refuses redirect and TLS failures without leaking errors', async () => {
    for (const options of [{ response: new Response(null, { status: 302, headers: { Location: 'https://other.example.ts.net' } }) }, { transportError: true }]) {
      const f = fixture(options); expect(await runSetupCli([], f.dependencies)).toBe(1);
      expect(f.stdout).toEqual([]); expect(f.counts().issued).toBe(0); expect(f.stderr.join('')).not.toContain('PRIVATE');
    }
  });
  test('explicit same-machine accepts literal loopback and warns only on terminal', async () => {
    const f = fixture({ origin: 'http://127.0.0.1:4080' });
    expect(await runSetupCli(['--same-machine'], f.dependencies)).toBe(0);
    expect(f.terminal.join('')).toContain('not physical-phone ready');
    const alias = fixture({ origin: 'http://localhost:4080' });
    expect(await runSetupCli(['--same-machine'], alias.dependencies)).toBe(1); expect(alias.counts().probes).toBe(0);
  });
  test('unexpected local read failures are safe and do not probe', async () => {
    const f = fixture(); f.dependencies.readLocal = async () => { throw new Error('MOCK PRIVATE PATH'); };
    expect(await runSetupCli(['--print-origin'], f.dependencies)).toBe(1); expect(f.counts().probes).toBe(0);
    expect(f.stdout).toEqual([]); expect(f.stderr.join('')).not.toContain('PRIVATE');
  });
  test('rejects proof arguments without reflecting them', async () => {
    const f = fixture(); expect(await runSetupCli(['MOCK-SECRET-ARGV'], f.dependencies)).toBe(2);
    expect(f.stderr.join('')).not.toContain('MOCK-SECRET-ARGV'); expect(f.counts().probes).toBe(0);
  });
});

describe('source CLI with real local persistence and trusted mock HTTP descriptor', () => {
  test('print-origin requires an existing durable identity, without providers, keys or a terminal', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lemon-setup-cli-'));
    let configured = false;
    // Mock product HTTP descriptor, not a real backend/controller/provider.
    const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(request): Response {
      expect(new URL(request.url).pathname).toBe('/v1/setup');
      expect(request.headers.has('Authorization')).toBe(false);
      return Response.json({ product: 'lemon_bot', apiVersion: 1, instanceId: 'durable-local-id', version: 'test',
        publicUrl: `http://127.0.0.1:${server.port}`, setupRequired: !configured, capabilities: { pairing: true } });
    } });
    const origin = `http://127.0.0.1:${server.port}`;
    const cli = fileURLToPath(new URL('../../src/cli.ts', import.meta.url));
    const args = [process.execPath, cli, 'setup', '--same-machine', '--print-origin'];
    const environment = {
      PATH: process.env.PATH, HOME: directory,
      LEMON_BOT_DATA_DIR: directory, LEMON_BOT_PUBLIC_URL: origin,
    };
    async function invoke() {
      const child = Bun.spawn(args, { env: environment, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
      ]);
      return { stdout, stderr, exitCode };
    }
    try {
      const missing = await invoke();
      expect(missing.exitCode).toBe(1); expect(missing.stdout).toBe('');
      expect(missing.stderr).not.toContain(directory);
      expect(await stat(join(directory, 'product.sqlite')).then(() => true, () => false)).toBe(false);
      const db = new Database(join(directory, 'product.sqlite'));
      db.exec('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)');
      db.query('INSERT INTO metadata VALUES (?,?)').run('instanceId', JSON.stringify('durable-local-id'));
      db.close();
      for (const existingWorkspace of [false, true]) {
        configured = existingWorkspace;
        if (configured) {
          const existing = new Database(join(directory, 'product.sqlite'));
          existing.query('INSERT INTO metadata VALUES (?,?)').run('workspaceId', JSON.stringify('workspace'));
          existing.close();
        }
        expect(await invoke()).toEqual({ stdout: `${origin}\n`, stderr: '', exitCode: 0 });
      }
      const unchanged = new Database(join(directory, 'product.sqlite'), { readonly: true });
      try { expect(unchanged.query('SELECT count(*) AS count FROM metadata').get()).toEqual({ count: 2 }); }
      finally { unchanged.close(); }
      expect(await stat(join(directory, 'master.key')).then(() => true, () => false)).toBe(false);
      expect(args).toEqual([process.execPath, cli, 'setup', '--same-machine', '--print-origin']);
    } finally {
      server.stop(true);
      await rm(directory, { recursive: true, force: true });
    }
  });
});
