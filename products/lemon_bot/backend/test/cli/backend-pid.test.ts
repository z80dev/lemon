import { expect, test } from 'bun:test';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { recordBackendPid } from '../../src/cli/backend-pid';
import { createBackend } from '../../src/index';
import { loadConfiguration } from '../../src/core/config';

// Real listener and private state, but no real controller/provider or installed service.
test('record exists only after listen and is removed on clean stop', async () => {
  const HOME = await mkdtemp(join(tmpdir(), 'lifecycle-consumers-pid-'));
  const dataDir = join(HOME, 'data');
  const configuration = await loadConfiguration({ HOME, LEMON_BOT_DATA_DIR: dataDir, LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:1/ws', LEMON_BOT_OPERATOR_TOKEN: 'MOCK-controller' });
  configuration.config.port = 0;
  const backend = await createBackend(configuration.config, configuration.key);
  let path = '';
  try {
    expect(await stat(join(dataDir, 'run')).catch(() => null)).toBeNull();
    const server = backend.start(); path = join(dataDir, 'run', `lemon-bot-${server.port}.json`);
    const record = JSON.parse(await readFile(path, 'utf8'));
    expect(record).toMatchObject({ pid: process.pid, port: server.port, instanceId: backend.services.store.metadata('instanceId') });
    expect(record.startedAt).toBe(Bun.spawnSync(['ps', '-o', 'lstart=', '-p', String(process.pid)], { env: { ...process.env, LC_ALL: 'C' } }).stdout.toString().trim());
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    await backend.stop(); expect(await stat(path).catch(() => null)).toBeNull();
  } finally { await backend.stop(); await rm(HOME, { recursive: true, force: true }); }
});

test('cleanup never removes a replacement process record', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lifecycle-consumers-replaced-'));
  try {
    const remove = recordBackendPid(directory, 45124, 'test-instance');
    const path = join(directory, 'run/lemon-bot-45124.json');
    await writeFile(path, '{"pid":42}'); remove();
    expect(await readFile(path, 'utf8')).toBe('{"pid":42}');
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('foreground CLI removes its record on SIGTERM', async () => {
  const HOME = await mkdtemp(join(tmpdir(), 'lifecycle-consumers-signal-'));
  const reserve = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response() });
  const port = reserve.port!; await reserve.stop(true);
  const dataDir = join(HOME, 'data'), path = join(dataDir, 'run', `lemon-bot-${port}.json`);
  const child = Bun.spawn([process.execPath, new URL('../../src/cli.ts', import.meta.url).pathname, '--no-open'], {
    env: { HOME, PATH: process.env.PATH, LEMON_BOT_DATA_DIR: dataDir, LEMON_BOT_PORT: String(port), LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:1/ws', LEMON_BOT_OPERATOR_TOKEN: 'MOCK-controller' },
    stdin: 'ignore', stdout: 'pipe', stderr: 'ignore',
  });
  try {
    // The startup line is emitted after the record is committed; await that signal, not a guessed sleep.
    const reader = child.stdout.getReader(); let output = '';
    try {
      while (!output.includes('Lemon Bot listening at')) {
        const chunk = await reader.read(); if (chunk.done) break;
        output += new TextDecoder().decode(chunk.value);
      }
    } finally { reader.releaseLock(); }
    expect(output).toContain('Lemon Bot listening at');
    expect(await stat(path)).not.toBeNull();
    child.kill('SIGTERM'); expect(await child.exited).toBe(0);
    expect(await stat(path).catch(() => null)).toBeNull();
  } finally { if (child.exitCode === null) { child.kill('SIGTERM'); await child.exited; } await rm(HOME, { recursive: true, force: true }); }
}, 10000);
