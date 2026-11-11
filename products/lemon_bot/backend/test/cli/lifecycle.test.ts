import { expect, test } from 'bun:test';
import { parseServiceStatus, service, spawn, type ServiceStatus } from '../../src/cli/lifecycle';

const status: ServiceStatus = { schema: 1, manager: 'launchd', persistence: 'login', linger: null, units: [{ role: 'worker', name: 'studio', state: 'needs_reauthorization', detail: 'node_authentication_failed' }] };
test('non-zero service receipt preserves authoritative parked state', async () => {
  const result = await service('/tmp/mock-lemon', ['status', 'worker', '--name', 'studio'], async (_executable, args) => {
    expect(args).toEqual(['service', 'status', 'worker', '--name', 'studio', '--json']);
    return { exitCode: 1, stdout: JSON.stringify(status), stderr: '' };
  });
  expect(result).toEqual({ exitCode: 1, status });
  expect(() => parseServiceStatus(JSON.stringify({ ...status, schema: 2 }))).toThrow();
  expect(() => parseServiceStatus(JSON.stringify(status) + '\nprogress')).toThrow();
});

test('local service status preserves and validates the configured worker wrapper', () => {
  for (const execWrapper of [undefined, null, '/Applications/Lemon Bot.app/Contents/MacOS/Worker']) {
    const value = { ...status, units: [{ ...status.units[0]!, execWrapper }] };
    expect(parseServiceStatus(JSON.stringify(value)).units[0]?.execWrapper).toBe(execWrapper);
  }
  expect(() => parseServiceStatus(JSON.stringify({ ...status, units: [{ ...status.units[0], execWrapper: 7 }] }))).toThrow();
});

test('missing/malformed enrollment receipt is unknown, never retried', async () => {
  let calls = 0;
  expect(await service('/tmp/mock', ['install', 'worker'], async () => { calls++; throw new Error('PRIVATE'); })).toEqual({ exitCode: 1, status: null });
  expect(calls).toBe(1);
});

test('real process transport keeps secret in stdin, not argv or environment', async () => {
  const secret = 'one-use-private-code';
  const result = await spawn('/bin/sh', ['-c', 'IFS= read -r code; printf %s "$code" | wc -c | tr -d " "'], { stdin: `${secret}\n` });
  expect(result).toEqual({ exitCode: 0, stdout: String(secret.length) + '\n', stderr: '' });
});
