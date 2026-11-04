import { afterEach, expect, test } from 'bun:test';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPrivateCodec, loadConfiguration, localSettings, readManagedToken, saveControllerChoice } from '../../src/core/config';

const directories: string[] = [];
afterEach(async () => { for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true }); });
async function home(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-bot-config-'));
  directories.push(directory);
  return directory;
}

test('with no settings the backend attaches to the Lemon runtime on this machine', async () => {
  const HOME = await home();
  const launcher = join(HOME, '.lemon', 'bin', 'lemon');
  await mkdir(join(HOME, '.lemon', 'bin'), { recursive: true }); await writeFile(launcher, '#!/bin/sh\n'); await chmod(launcher, 0o755);
  const { config, controllerSource } = await loadConfiguration({ HOME });
  expect(controllerSource).toBe('default');
  expect(config).toMatchObject({
    dataDir: join(HOME, '.lemon', 'lemon_bot'), host: '127.0.0.1', port: 4100, publicUrl: 'http://127.0.0.1:4100',
    controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: '', operatorTokenFile: join(HOME, '.lemon', 'run', 'control-plane-4040.token'),
    runtimeLauncher: launcher,
  });
});

test('the local control port follows the launchers: explicit LEMON_CONTROL_PLANE_PORT, then ports.env', async () => {
  const HOME = await home();
  await mkdir(join(HOME, '.lemon'), { recursive: true });
  await writeFile(join(HOME, '.lemon', 'ports.env'), 'LEMON_WEB_PORT=4081\nLEMON_CONTROL_PLANE_PORT=5050\n');
  expect((await loadConfiguration({ HOME })).config).toMatchObject({ controlUrl: 'ws://127.0.0.1:5050/ws', operatorTokenFile: join(HOME, '.lemon', 'run', 'control-plane-5050.token') });
  expect((await loadConfiguration({ HOME, LEMON_CONTROL_PLANE_PORT: '6060' })).config.controlUrl).toBe('ws://127.0.0.1:6060/ws');
});

test('a same-machine credential is never sent to a controller on another machine', async () => {
  const HOME = await home();
  const remote = { HOME, LEMON_BOT_CONTROL_URL: 'wss://desktop.example/ws', LEMON_CONTROL_PLANE_OPERATOR_TOKEN: 'local-runtime-token' };
  await expect(loadConfiguration(remote)).rejects.toThrow('LEMON_BOT_OPERATOR_TOKEN is required for a controller on another machine.');
  const { config, controllerSource } = await loadConfiguration({ ...remote, LEMON_BOT_OPERATOR_TOKEN: 'remote-token' });
  expect(controllerSource).toBe('environment');
  expect(config).toMatchObject({ controlUrl: 'wss://desktop.example/ws', operatorToken: 'remote-token', operatorTokenFile: undefined, runtimeLauncher: undefined });
});

test('a saved remote choice is used, keeps its token encrypted, and yields to explicit environment', async () => {
  const HOME = await home();
  const first = await loadConfiguration({ HOME });
  await saveControllerChoice(first.config.dataDir, createPrivateCodec(first.key), { mode: 'remote', url: 'wss://desktop.example/ws', token: 'saved-remote-token' });
  expect(await readFile(join(first.config.dataDir, 'controller.json'), 'utf8')).not.toContain('saved-remote-token');
  const saved = await loadConfiguration({ HOME });
  expect(saved.controllerSource).toBe('saved');
  expect(saved.config).toMatchObject({ controlUrl: 'wss://desktop.example/ws', operatorToken: 'saved-remote-token', operatorTokenFile: undefined });
  const explicit = await loadConfiguration({ HOME, LEMON_BOT_OPERATOR_TOKEN: 'explicit-local-token' });
  expect(explicit.controllerSource).toBe('environment');
  expect(explicit.config).toMatchObject({ controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: 'explicit-local-token' });
});

test('a non-loopback listener needs an explicit public origin', () => {
  expect(() => localSettings({ HOME: '/unused', LEMON_BOT_HOST: '0.0.0.0' })).toThrow('LEMON_BOT_PUBLIC_URL is required');
  expect(localSettings({ HOME: '/unused', LEMON_BOT_HOST: '0.0.0.0', LEMON_BOT_PUBLIC_URL: 'https://desktop.example' }).publicUrl.origin).toBe('https://desktop.example');
});

test('the managed credential must be a private 0600 file with a launcher-format token', async () => {
  const directory = await home();
  const file = join(directory, 'control-plane-4040.token');
  expect(readManagedToken(file)).toEqual({ problem: 'missing' });
  await writeFile(file, `${'f'.repeat(64)}\n`); await chmod(file, 0o640);
  expect(readManagedToken(file)).toEqual({ problem: 'unsafe' });
  await chmod(file, 0o600);
  expect(readManagedToken(file)).toEqual({ token: 'f'.repeat(64) });
  await writeFile(file, 'not-a-launcher-token\n');
  expect(readManagedToken(file)).toEqual({ problem: 'unsafe' });
});

test('startup prints a configuration error without a stack and exits 1', async () => {
  const HOME = await home();
  const child = Bun.spawn([process.execPath, 'src/index.ts'], {
    cwd: new URL('../..', import.meta.url).pathname,
    env: { PATH: process.env.PATH, HOME, LEMON_BOT_CONTROL_URL: 'wss://desktop.example/ws' },
    stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
  });
  const [status, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  expect(status).toBe(1);
  expect(stderr).toBe('LEMON_BOT_OPERATOR_TOKEN is required for a controller on another machine. See the env table in products/lemon_bot/backend/README.md.\n');
});
