import { expect, test } from 'bun:test';
import { instanceUptime } from '../src/features/settings/instance';

test('humanizes instance uptime without treating zero as unavailable', () => {
  for (const [milliseconds, expected] of [[-1, '0s'], [0, '0s'], [999, '0s'], [12000, '12s'], [61000, '1m 1s'], [3661000, '1h 1m'], [90061000, '1d 1h']] as const) {
    expect(instanceUptime(milliseconds)).toBe(expected);
  }
});
