import test from 'node:test';
import assert from 'node:assert/strict';
import { ExpiringCache } from '../src/cache.ts';
import { createSessions } from '../src/sessions.ts';
test('expiry boundary, no sliding expiration, purge every entry', () => {
  let time = 0; const c = new ExpiringCache(3, () => time);
  c.set('a', 1, 5); c.set('b', 2, 2); c.set('c', 3, 9);
  time = 1; assert.equal(c.get('a'), 1);
  time = 2; assert.equal(c.has('b'), false); assert.equal(c.size, 2);
  time = 5; assert.equal(c.get('a'), undefined); assert.equal(c.size, 1);
  time = 9; assert.equal(c.size, 0);
});
test('recency, replacement, undefined, and expired capacity victim', () => {
  let time = 0; const c = new ExpiringCache<any>(2, () => time);
  c.set('a', 1, 10); c.set('b', undefined, 10);
  assert.equal(c.has('b'), true); c.get('a'); c.set('c', 3, 10);
  assert.equal(c.has('b'), false); assert.equal(c.get('a'), 1);
  c.set('a', 4, 20); assert.equal(c.size, 2); assert.equal(c.get('c'), 3);
  c.has('a'); c.set('d', 5, 20); assert.equal(c.has('a'), false);
  const d = new ExpiringCache(2, () => time);
  d.set('__proto__', 1, 100); d.set('short', 2, 1);
  time = 1; d.set('new', 3, 100); assert.equal(d.get('__proto__'), 1);
  d.set('new', 9, 0); assert.equal(d.has('new'), false);
});
test('validation leaves entries unchanged and samples clock once', () => {
  for (const n of [0, -1, 1.5, NaN, Infinity]) assert.throws(() => new ExpiringCache(n), RangeError);
  let calls = 0; const c = new ExpiringCache(2, () => { calls++; return 0; });
  for (const operation of [() => c.set('a', 1, 10), () => c.get('a'), () => c.has('a'), () => c.size]) {
    const before = calls; operation(); assert.equal(calls - before, 1);
  }
  for (const ttl of [-1, NaN, Infinity]) assert.throws(() => c.set('a', 99, ttl), RangeError);
  assert.equal(c.get('a'), 1);
});
test('sessions expire at their deadline', () => {
  let time = 0; const s = createSessions(() => time); s.login('t', 'Ada', 10);
  time = 10; assert.equal(s.lookup('t'), undefined); assert.equal(s.count(), 0);
});
