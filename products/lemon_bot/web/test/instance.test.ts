import { expect, test } from 'bun:test';
import { instanceBuild, instanceUptime } from '../src/features/settings/instance';

test('humanizes instance uptime without treating zero as unavailable', () => {
  for (const [milliseconds, expected] of [[-1, '0s'], [0, '0s'], [999, '0s'], [12000, '12s'], [61000, '1m 1s'], [3661000, '1h 1m'], [90061000, '1d 1h']] as const) {
    expect(instanceUptime(milliseconds)).toBe(expected);
  }
});

test('build identity omits absent values and shortens the commit', () => {
  expect(instanceBuild({ version: '2026.10.9', build: { runtimeMode: 'release-runtime', channel: 'preview', commit: 'abc123456789' } })).toBe('2026.10.9 · preview · abc1234');
  expect(instanceBuild({ version: '2026.10.9', build: null })).toBe('2026.10.9');
  expect(instanceBuild({ version: null, build: { runtimeMode: 'source-dev', channel: null, commit: 'abc' } })).toBe('abc');
  expect(instanceBuild({ version: null, build: null })).toBe('Unavailable');
});
