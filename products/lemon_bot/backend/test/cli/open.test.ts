import { describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir, userInfo } from 'node:os';
import { join } from 'node:path';
import { createPrivateCodec } from '../../src/core/config';
import { createMutationDigest } from '../../src/core/mutations';
import { Store } from '../../src/core/store';
import { productVersion } from '../../src/core/version';
import { localBackendChallengeProof, type LocalTicketRow } from '../../src/core/local-signin';
import type { BackendServices } from '../../src/core/services';
import { firstStartSignIn } from '../../src/index';
import { openPrivateStore, readInstanceId } from '../../src/cli/local-store';
import { probeLocalBackend, runOpenCli, type OpenCliDependencies } from '../../src/cli/open';

async function fixture() {
  const dataDir = await mkdtemp(join(tmpdir(), 'bot-open-'));
  const store = new Store(join(dataDir, 'product.sqlite')); const key = new Uint8Array(32).fill(17);
  const codec = createPrivateCodec(key); store.setMetadata('encryptionKeyCheck', codec.encrypt('lemon_bot_private_key_v1'));
  await writeFile(join(dataDir, 'master.key'), Buffer.from(key).toString('base64'), { mode: 0o600 });
  let now = 1_000_000; let signal: ((value: 'SIGINT' | 'SIGTERM' | 'exit') => void) | undefined;
  let terminalClosed = false; let opened = ''; let html = ''; let mode = 0; let directoryMode = 0;
  const stdout: string[] = []; const stderr: string[] = []; const tty: string[] = [];
  const rows = () => store.list<LocalTicketRow>('signInTickets');
  const deps: OpenCliDependencies = {
    env: { LEMON_BOT_DATA_DIR: dataDir }, platform: 'darwin', openerAvailable: true,
    now: () => now,
    async sleep(ms) { now += ms; const row = rows()[0]; if (row) store.put('signInTickets', { ...row, redeemedAtMs: now }); },
    onSignal(callback) { signal = callback; return () => { signal = undefined; }; },
    async readLocal(directory) { return readInstanceId(directory); }, openPrivateStore,
    async probe(_origin, nonce) {
      const identity = { product: 'lemon_bot' as const, instanceId: store.metadata<string>('instanceId')!, version: productVersion };
      return { ...identity, proof: localBackendChallengeProof(createMutationDigest(key), nonce, identity) };
    },
    openTerminal() { return { write(value) { tty.push(value); }, close() { terminalClosed = true; } }; },
    async openPath(path) { opened = path; html = await readFile(path, 'utf8'); mode = (await stat(path)).mode & 0o777; directoryMode = (await stat(join(dataDir, 'handoff'))).mode & 0o777; return true; },
    stdout(value) { stdout.push(value); }, stderr(value) { stderr.push(value); },
  };
  return { dataDir, store, key, deps, stdout, stderr, tty, rows,
    advance(ms: number) { now += ms; }, signal(value: 'SIGINT' | 'SIGTERM' | 'exit') { signal?.(value); },
    captured: () => ({ opened, html, mode, directoryMode, terminalClosed }),
    async close() { store.close(); await rm(dataDir, { recursive: true, force: true }); },
  };
}

describe('lemon-bot open with private persistence and injected IO', () => {
  test('local success: ticket never appears in argv/stdout/stderr, private file removed', async () => {
    const f = await fixture();
    try {
      const args: string[] = []; expect(await runOpenCli(args, f.deps)).toBe(0);
      const { opened, html, mode, directoryMode } = f.captured();
      const ticket = html.match(/lemonbot-signin=([A-Za-z0-9_-]{43})/)![1]!;
      expect(mode).toBe(0o600); expect(directoryMode).toBe(0o700);
      expect(opened).toMatch(/\/handoff\/open-lst_[A-Za-z0-9_-]+\.html$/);
      expect(opened).not.toContain(ticket); expect(JSON.stringify(args)).not.toContain(ticket);
      expect(f.stdout.join('')).not.toContain(ticket); expect(f.stderr.join('')).not.toContain(ticket);
      expect(f.stdout.join('')).toContain('Signed in.'); expect(await Bun.file(opened).exists()).toBe(false);
    } finally { await f.close(); }
  });
  for (const args of [['--bad'], ['--headless', '--headless'], ['secret-url']]) test(`rejects arguments ${args[0]}`, async () => {
    const f = await fixture(); try { expect(await runOpenCli(args, f.deps)).toBe(2); expect(f.rows()).toHaveLength(0); } finally { await f.close(); }
  });
  for (const scenario of ['host', 'unreachable', 'instance', 'product', 'version', 'missing'] as const) test(`preflight ${scenario} refuses without minting`, async () => {
    const f = await fixture();
    try {
      if (scenario === 'host') Object.assign(f.deps.env, { LEMON_BOT_HOST: '0.0.0.0', LEMON_BOT_PUBLIC_URL: 'https://server.example' });
      else if (scenario === 'missing') f.deps.readLocal = async () => { throw new Error('PRIVATE'); };
      else f.deps.probe = async (_origin, nonce) => {
        if (scenario === 'unreachable') throw new Error('PRIVATE');
        const identity = { product: 'lemon_bot' as const, instanceId: scenario === 'instance' ? 'wrong' : f.store.metadata<string>('instanceId')!, version: scenario === 'version' ? '0.0.0' : productVersion };
        if (scenario === 'product') return { ...identity, product: 'wrong', proof: '0'.repeat(64) };
        return { ...identity, proof: localBackendChallengeProof(createMutationDigest(f.key), nonce, identity) };
      };
      expect(await runOpenCli([], f.deps)).toBe(1); expect(f.rows()).toHaveLength(0);
      expect(await Bun.file(join(f.dataDir, 'handoff')).exists()).toBe(false);
      expect(f.stderr.join('')).not.toContain('PRIVATE');
    } finally { await f.close(); }
  });
  test('replayed public descriptor without the private key is refused before ticket delivery', async () => {
    const f = await fixture();
    try {
      f.deps.probe = async () => ({ product: 'lemon_bot', instanceId: f.store.metadata('instanceId'), version: productVersion, proof: '0'.repeat(64) });
      expect(await runOpenCli([], f.deps)).toBe(1);
      expect(f.rows()).toHaveLength(0);
      expect(f.captured().opened).toBe('');
      expect(f.stderr.join('')).toContain('different Lemon Bot');
    } finally { await f.close(); }
  });
  test('expiry removes file and emits the 15-second hint exactly once', async () => {
    const f = await fixture();
    try {
      f.deps.sleep = async ms => { f.advance(ms); };
      expect(await runOpenCli([], f.deps)).toBe(1);
      expect(f.rows()[0]!.expiresAtMs).toBeLessThanOrEqual(f.deps.now());
      expect(f.stdout.filter(line => line.includes("Browser didn't open"))).toHaveLength(1);
      expect(await Bun.file(f.captured().opened).exists()).toBe(false);
    } finally { await f.close(); }
  });
  for (const signal of ['SIGINT', 'SIGTERM', 'exit'] as const) test(`${signal} removes pending handoff`, async () => {
    const f = await fixture();
    try {
      f.deps.sleep = async () => { f.signal(signal); };
      expect(await runOpenCli([], f.deps)).toBe(signal === 'SIGINT' ? 130 : 143);
      expect(await Bun.file(f.captured().opened).exists()).toBe(false); expect(f.rows()).toHaveLength(0);
    } finally { await f.close(); }
  });
  test('--no-wait keeps file for browser to read and backend to clean up', async () => {
    const f = await fixture();
    try {
      f.deps.sleep = async () => { throw new Error('must not poll'); };
      expect(await runOpenCli(['--no-wait'], f.deps)).toBe(0);
      expect(await Bun.file(f.captured().opened).exists()).toBe(true); expect(f.rows()[0]!.redeemedAtMs).toBeNull();
    } finally { await f.close(); }
  });
  test('headless proof only reaches tty with five-minute lifetime and SSH tunnel command', async () => {
    const f = await fixture();
    try {
      f.deps.env.SSH_CONNECTION = '192.0.2.1 123 192.0.2.2 22';
      expect(await runOpenCli(['--no-wait'], f.deps)).toBe(0);
      const output = f.tty.join(''); const ticket = output.match(/lemonbot-signin=([A-Za-z0-9_-]{43})/)![1]!;
      expect(output).toContain(`ssh -N -L 4100:127.0.0.1:4100 ${userInfo().username}@192.0.2.2`);
      expect(f.stdout.join('')).not.toContain(ticket); expect(f.stderr.join('')).not.toContain(ticket);
      const row = f.rows()[0]!; expect(row.channel).toBe('terminal'); expect(row.expiresAtMs - row.createdAtMs).toBe(300000);
      expect(f.captured().terminalClosed).toBe(true); expect(row.handoffFile).toBeNull();
    } finally { await f.close(); }
  });
  test('no controlling terminal refuses before minting', async () => {
    const f = await fixture();
    try { f.deps.openTerminal = () => { throw new Error('PRIVATE'); }; expect(await runOpenCli(['--headless'], f.deps)).toBe(2); expect(f.rows()).toHaveLength(0); } finally { await f.close(); }
  });
  for (const terminalAvailable of [true, false]) test(`opener failure revokes browser ticket; terminal=${terminalAvailable}`, async () => {
    const f = await fixture(); let path = '';
    try {
      f.deps.openPath = async value => { path = value; return false; };
      if (!terminalAvailable) f.deps.openTerminal = () => { throw new Error('PRIVATE'); };
      expect(await runOpenCli(['--no-wait'], f.deps)).toBe(terminalAvailable ? 0 : 1);
      expect(await Bun.file(path).exists()).toBe(false);
      expect(f.rows().map(row => row.channel)).toEqual(terminalAvailable ? ['terminal'] : []);
    } finally { await f.close(); }
  });
  test('unsafe handoff write revokes the ticket without opening the browser', async () => {
    const f = await fixture();
    try {
      await writeFile(join(f.dataDir, 'handoff'), 'not a directory');
      expect(await runOpenCli([], f.deps)).toBe(1); expect(f.rows()).toHaveLength(0); expect(f.captured().opened).toBe('');
    } finally { await f.close(); }
  });
});

describe('first interactive start uses the same in-process delivery', () => {
  for (const scenario of ['loopback', 'headless', 'no-open', 'nonloopback', 'noninteractive', 'configured'] as const) test(scenario, async () => {
    const f = await fixture(); const writes: string[] = []; let legacyOffered = 0; let legacyOpened = '';
    try {
      if (scenario === 'configured') f.store.setMetadata('workspaceId', 'existing');
      if (scenario === 'headless') f.deps.env.SSH_TTY = '/dev/pts/mock';
      // Deliberately limited mock: this path uses only store, clock, digest and configuration.
      const services = { store: f.store, now: f.deps.now, mutations: { digest: createMutationDigest(f.key) }, config: { dataDir: f.dataDir, loopbackOrigin: scenario === 'nonloopback' ? null : 'http://127.0.0.1:4100', publicUrl: 'https://server.example' } } as unknown as BackendServices;
      await firstStartSignIn(services, { interactive: scenario !== 'noninteractive', write(value) { writes.push(value); } }, { openBrowser: scenario !== 'no-open' }, f.deps, { offer() { legacyOffered++; }, open(value) { legacyOpened = value; } });
      expect(f.rows()).toHaveLength(scenario === 'loopback' || scenario === 'headless' ? 1 : 0);
      expect(f.tty.join('')).not.toContain('setup code');
      expect(legacyOffered).toBe(scenario === 'nonloopback' ? 1 : 0);
      expect(legacyOpened).toBe(scenario === 'nonloopback' ? 'https://server.example' : '');
      expect(writes.length).toBe(scenario === 'no-open' ? 1 : 0);
    } finally { await f.close(); }
  });
});

describe('bounded loopback preflight', () => {
  test('manual redirects and oversized JSON are refused', async () => {
    const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(request) { return new URL(request.url).search ? new Response('{}') : new Response('x'.repeat(16385)); } });
    try { await expect(probeLocalBackend(`http://127.0.0.1:${server.port}`, 'a'.repeat(43))).rejects.toThrow(); } finally { await server.stop(true); }
    const redirect = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch() { return Response.redirect('http://127.0.0.1:1', 302); } });
    try { await expect(probeLocalBackend(`http://127.0.0.1:${redirect.port}`, 'a'.repeat(43))).rejects.toThrow(); } finally { await redirect.stop(true); }
  });
});
