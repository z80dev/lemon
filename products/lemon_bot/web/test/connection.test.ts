import { expect, test } from 'bun:test';
import { LemonBotError, type RealtimeState } from '@lemon-bot/sdk';
import { connectionIssue, connectionLabel, sessionEnded } from '../src/connection-state';

test('every realtime state has a human label; controller and network failures remain distinct', () => {
  const states: RealtimeState[] = ['connecting', 'authenticating', 'syncing', 'replaying', 'live', 'reconnecting', 'unauthenticated', 'forbidden', 'error', 'closed'];
  expect(states.map(state => connectionLabel(state, true))).toEqual(['Connecting', 'Signing in', 'Updating', 'Catching up', 'Connected', 'Reconnecting', 'Session ended', 'Session ended', 'Connection failed', 'Disconnected']);
  expect(connectionLabel('live', true, false)).toBe('Lemon disconnected');
  expect(connectionLabel('live', false, false)).toBe('Offline');
});

test('classifies transport, proxy, server, controller, and ended-session failures', () => {
  expect(connectionIssue('error', true, false, new TypeError('fetch failed')).layer).toBe('backend');
  for (const status of [502, 504, 500, 503]) {
    const error = new LemonBotError({ code: 'upstream_unavailable', message: 'Internal detail', requestId: 'request_1', retrySafe: true }, { status });
    const issue = connectionIssue('error', true, false, error);
    expect(issue.layer).toBe('server');
    expect(issue.reason.includes('proxy')).toBe(status === 502 || status === 504);
    expect(issue.reason).not.toContain('Internal detail');
  }
  expect(connectionIssue('live', true, false, undefined).layer).toBe('controller');
  expect(connectionIssue('reconnecting', false, false, undefined).layer).toBe('offline');
  for (const status of [401, 403]) {
    const error = new LemonBotError({ code: status === 401 ? 'unauthenticated' : 'forbidden', message: 'Revoked', requestId: '', retrySafe: false }, { status });
    expect(sessionEnded(error)).toBe(true);
    expect(connectionIssue('error', true, false, error).title).toBe('Your session ended. Sign in again.');
  }
  expect(connectionIssue('forbidden', true, true, undefined).layer).toBe('session');
});
