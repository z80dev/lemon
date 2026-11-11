import test from 'node:test';
import assert from 'node:assert/strict';
import { createSessions } from '../src/sessions.ts';
test('session lookup', () => {
  const sessions = createSessions(() => 100);
  sessions.login('token', 'Ada', 50);
  assert.equal(sessions.lookup('token'), 'Ada');
});
