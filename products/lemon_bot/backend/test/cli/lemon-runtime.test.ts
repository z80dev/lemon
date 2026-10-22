import { afterEach, expect, test } from 'bun:test';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPrivateCodec, loadConfiguration } from '../../src/core/config';
import { prepareController, type ControllerPreparation } from '../../src/cli/lemon-runtime';
import type { ConnectTerminal } from '../../src/cli/connect';

const directories: string[] = [];
afterEach(async () => { for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true }); });

async function harness() {
  const HOME = await mkdtemp(join(tmpdir(), 'lemon-bot-choice-')); directories.push(HOME);
  const launcher = join(HOME, '.lemon', 'bin', 'lemon');
  await mkdir(join(HOME, '.lemon', 'bin'), { recursive: true }); await writeFile(launcher, '#!/bin/sh\n'); await chmod(launcher, 0o755);
  const environment = { HOME };
  const state = { healthy: false, answers: [] as string[], output: [] as string[], launches: [] as string[][], verified: [] as string[] };
  const terminal: ConnectTerminal = {
    interactive: true, write: message => { state.output.push(message); }, sensitive: message => { state.output.push(message); },
    read: async label => { state.output.push(label); const answer = state.answers.shift(); if (answer === undefined) throw new Error(`unexpected prompt: ${label}`); return answer; },
  };
  const load = () => loadConfiguration(environment);
  async function prepare(answers: string[], choose = false): Promise<ControllerPreparation> {
    state.answers = answers; state.output = []; state.launches = [];
    const { config, key, controllerSource } = await load();
    const input: ControllerPreparation = {
      terminal, environment, config, codec: createPrivateCodec(key), source: controllerSource, choose,
      fetch: (async () => Response.json({ ok: state.healthy })) as unknown as typeof fetch,
      launch: async (_launcher, args) => { state.launches.push(args); return 0; },
      verify: async (url, token) => { state.verified.push(`${url} ${token}`); return null; },
    };
    await prepareController(input);
    expect(state.answers).toEqual([]);
    return input;
  }
  return { state, load, prepare, launcher };
}

test('first start on this machine offers to start a stopped Lemon, then remembers the choice', async () => {
  const h = await harness();
  const prepared = await h.prepare(['', '']);
  expect(h.state.output.join('\n')).toContain('1) This machine (installed, not running)');
  expect(h.state.launches).toEqual([['setup', '--if-required'], ['daemon']]);
  expect(prepared.config).toMatchObject({ controlUrl: 'ws://127.0.0.1:4040/ws', runtimeLauncher: h.launcher });
  expect((await h.load()).controllerSource).toBe('saved');
  // The saved choice skips the question, and a running Lemon needs no start.
  h.state.healthy = true;
  await h.prepare([]);
  expect(h.state.launches).toEqual([]);
});

test('declining the start leaves Lemon stopped and still saves this machine', async () => {
  const h = await harness();
  await h.prepare(['1', 'n']);
  expect(h.state.launches).toEqual([]);
  expect((await h.load()).controllerSource).toBe('saved');
});

test('another machine is verified, saved and used without the local launcher; --choose-lemon switches back', async () => {
  const h = await harness();
  h.state.healthy = true;
  const remote = await h.prepare(['2', 'ws://desktop.example/ws', 'wss://desktop.example/ws', 'remote-operator-token']);
  expect(h.state.output.join('\n')).toContain('requires wss://');
  expect(h.state.verified).toEqual(['wss://desktop.example/ws remote-operator-token']);
  expect(remote.config).toMatchObject({ controlUrl: 'wss://desktop.example/ws', operatorToken: 'remote-operator-token', operatorTokenFile: undefined, runtimeLauncher: undefined });
  expect((await h.load()).config.controlUrl).toBe('wss://desktop.example/ws');
  await h.prepare([]);
  expect(h.state.output.join('\n')).toContain('Using Lemon at wss://desktop.example/ws.');
  const local = await h.prepare(['1'], true);
  expect(h.state.output.join('\n')).toContain('Choose 1 or 2 [2]');
  expect(local.config).toMatchObject({ controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: '', runtimeLauncher: h.launcher });
  expect((await h.load()).config.controlUrl).toBe('ws://127.0.0.1:4040/ws');
});
