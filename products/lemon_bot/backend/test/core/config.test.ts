import { expect, test } from 'bun:test';
import { loadConfiguration } from '../../src/core/config';

const environment = {
  LEMON_BOT_DATA_DIR: '/unused-config-test',
  LEMON_BOT_OPERATOR_TOKEN: 'test-operator',
  LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:4040/ws',
  LEMON_BOT_PUBLIC_URL: 'http://127.0.0.1:4080',
};

for (const name of Object.keys(environment)) {
  for (const value of [undefined, '']) {
    test(`missing ${name} (${value === undefined ? 'unset' : 'empty'}) names the setting`, async () => {
      await expect(loadConfiguration({ ...environment, [name]: value })).rejects.toThrow(`${name} is required.`);
    });
  }
}

test('startup prints a missing setting without a stack and exits 1', async () => {
  const child = Bun.spawn([process.execPath, 'src/index.ts'], {
    cwd: new URL('../..', import.meta.url).pathname,
    env: { ...process.env, ...environment, LEMON_BOT_OPERATOR_TOKEN: undefined },
    stdout: 'pipe', stderr: 'pipe',
  });
  const [status, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  expect(status).toBe(1);
  expect(stderr).toBe('LEMON_BOT_OPERATOR_TOKEN is required. See the env table in products/lemon_bot/backend/README.md.\n');
});
