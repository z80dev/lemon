import { expect, test } from 'bun:test';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { foregroundStartup } from '../../src/cli/startup';

const cli = new URL('../../src/cli.ts', import.meta.url).pathname;
test('startup preserves service/no-open/non-terminal foreground mode', () => {
  expect(foregroundStartup([], true)).toBe(false);
  expect(foregroundStartup(['--choose-lemon'], true)).toBe(false);
  expect(foregroundStartup([], false)).toBe(true);
  expect(foregroundStartup(['--no-open'], true)).toBe(true);
  expect(foregroundStartup([], true, 'backend')).toBe(true);
});

test('help lists up/open without creating state; up dispatch validates its own arguments', async () => {
  const HOME = await mkdtemp(join(tmpdir(), 'lifecycle-consumers-cli-'));
  try {
    const invoke = async (args: string[]) => {
      const child = Bun.spawn([process.execPath, cli, ...args], { env: { HOME, PATH: '/usr/bin:/bin' }, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
      const [stdout, stderr, exitCode] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      return { stdout, stderr, exitCode };
    };
    const help = await invoke(['--help']); expect(help.exitCode).toBe(0);
    expect(help.stdout).toContain('lemon-bot up [--json]'); expect(help.stdout).toContain('lemon-bot open');
    expect(await stat(join(HOME, '.lemon')).catch(() => null)).toBeNull();
    expect((await invoke(['up', '--unsupported'])).exitCode).toBe(2);
    const up = await invoke(['up', '--json', '--no-open']);
    expect(up.exitCode).toBe(1);
    expect(JSON.parse(up.stdout.trim().split('\n').at(-1)!)).toMatchObject({ type: 'result', status: 'runtime_missing' });
    // `open` belongs to the local-auth CLI; dispatch must reach it after integration.
    const open = await invoke(['open', '--unsupported']); expect(open.exitCode).toBe(2);
    expect(open.stderr).not.toContain('Unsupported argument. Use lemon-bot --help.');
  } finally { await rm(HOME, { recursive: true, force: true }); }
});
