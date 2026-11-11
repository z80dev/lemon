import test from 'node:test';
import assert from 'node:assert/strict';
import { createHub } from '../src/hub.ts';
import type { Hub } from '../src/hub.ts';
import { attachAlarmRule, collectAlarms } from '../src/monitor.ts';
import type { MonitorEvents } from '../src/monitor.ts';

function capture(fn: () => unknown): unknown {
  try { fn(); } catch (error) { return error; }
  assert.fail('Expected a thrown error');
}

test('key identity, payload identity, duplicate registrations, and hub isolation', () => {
  const key = Symbol('event');
  interface Events { 1: object; 'one': object; [key]: object; '__proto__': object }
  const hub = createHub<Events>();
  const other = createHub<Events>();
  const payload = { n: 1 };
  const seen: object[] = [];
  const listener = (value: object) => { seen.push(value); };
  const first = hub.subscribe(key, listener);
  hub.subscribe(key, listener, { once: false });
  hub.subscribe('__proto__', listener);
  hub.publish(1, payload); other.publish(key, payload);
  assert.deepEqual(seen, []);
  hub.publish(key, payload); assert.equal(seen.length, 2); assert.equal(seen[0], payload); assert.equal(seen[1], payload);
  first(); first(); assert.equal(hub.listenerCount(key), 1);
  hub.publish('__proto__', payload); assert.equal(seen.length, 3);
  const distinct = createHub<{ [name: string]: number; [name: number]: number }>();
  const keys: string[] = [];
  distinct.subscribe(1, () => { keys.push('number'); });
  distinct.subscribe('1', () => { keys.push('string'); });
  distinct.publish(1, 0); distinct.publish('1', 0);
  assert.deepEqual(keys, ['number', 'string']);
});

test('snapshot excludes new registrations and skips removals before their turn', () => {
  const hub = createHub<{ tick: number }>();
  const seen: string[] = [];
  let removeB = () => {};
  let added = false;
  hub.subscribe('tick', n => {
    seen.push('a' + n); removeB();
    if (!added) { added = true; hub.subscribe('tick', value => { seen.push('d' + value); }); }
  });
  removeB = hub.subscribe('tick', n => { seen.push('b' + n); });
  hub.subscribe('tick', n => { seen.push('c' + n); });
  hub.publish('tick', 1); assert.deepEqual(seen, ['a1', 'c1']);
  assert.equal(hub.listenerCount('tick'), 3);
  hub.publish('tick', 2); assert.deepEqual(seen, ['a1', 'c1', 'a2', 'c2', 'd2']);
});

test('removing and resubscribing a callback does not revive an old snapshot', () => {
  const hub = createHub<{ event: number }>();
  const seen: number[] = [];
  const callback = (n: number) => { seen.push(n); };
  let replace = true;
  let remove = () => {};
  hub.subscribe('event', () => { if (replace) { replace = false; remove(); remove = hub.subscribe('event', callback); } });
  remove = hub.subscribe('event', callback);
  hub.publish('event', 1); assert.deepEqual(seen, []);
  hub.publish('event', 2); assert.deepEqual(seen, [2]);
  remove(); hub.publish('event', 3); assert.deepEqual(seen, [2]);
});

test('nested snapshots see new registrations and consume once entries globally', () => {
  const hub = createHub<{ tick: number }>();
  const seen: string[] = [];
  hub.subscribe('tick', n => {
    seen.push('a' + n);
    if (n === 1) {
      hub.subscribe('tick', value => { seen.push('d' + value); });
      hub.publish('tick', 2);
    }
  });
  hub.subscribe('tick', n => { seen.push('b' + n); assert.equal(hub.listenerCount('tick'), 3); }, { once: true });
  hub.subscribe('tick', n => { seen.push('c' + n); });
  hub.publish('tick', 1);
  assert.deepEqual(seen, ['a1', 'a2', 'b2', 'c2', 'd2', 'c1']);
  assert.equal(hub.listenerCount('tick'), 3);
});

test('once removal precedes callback and remains removed after throwing', () => {
  const hub = createHub<{ tick: number }>();
  const marker = new Error('once failure');
  const seen: number[] = [];
  const remove = hub.subscribe('tick', n => {
    assert.equal(hub.listenerCount('tick'), 1);
    seen.push(n); hub.publish('tick', 2); throw marker;
  }, { once: true });
  hub.subscribe('tick', n => { seen.push(n * 10); });
  const error = capture(() => hub.publish('tick', 1));
  assert.ok(error instanceof AggregateError); assert.deepEqual(error.errors, [marker]);
  assert.deepEqual(seen, [1, 20, 10]);
  remove(); remove(); hub.publish('tick', 3);
  assert.deepEqual(seen, [1, 20, 10, 30]);
});

test('all thrown values aggregate in callback order without corrupting future calls', () => {
  const hub = createHub<{ event: null }>();
  const marker = new Error('first');
  const values: unknown[] = [marker, undefined, 'bad', null, 0];
  const visited: number[] = [];
  for (let i = 0; i < values.length; i++) hub.subscribe('event', () => { visited.push(i); throw values[i]; });
  hub.subscribe('event', () => { visited.push(99); });
  for (let attempt = 0; attempt < 2; attempt++) {
    const error = capture(() => hub.publish('event', null));
    assert.ok(error instanceof AggregateError);
    assert.equal(error.message, 'listeners failed');
    assert.equal(error.errors.length, values.length);
    values.forEach((value, index) => assert.equal(error.errors[index], value));
  }
  assert.deepEqual(visited, [0, 1, 2, 3, 4, 99, 0, 1, 2, 3, 4, 99]);
});

test('nested aggregate errors remain nested and outer listeners continue', () => {
  const hub = createHub<{ parent: null; child: null }>();
  const childError = { reason: 'child' };
  const parentError = 'parent';
  const visited: string[] = [];
  hub.subscribe('child', () => { throw childError; });
  hub.subscribe('parent', () => { hub.publish('child', null); });
  hub.subscribe('parent', () => { visited.push('continued'); throw parentError; });
  const error = capture(() => hub.publish('parent', null));
  assert.ok(error instanceof AggregateError); assert.equal(error.errors.length, 2);
  assert.ok(error.errors[0] instanceof AggregateError);
  assert.equal(error.errors[0].errors[0], childError); assert.equal(error.errors[1], parentError);
  assert.deepEqual(visited, ['continued']);
});

test('unsubscribe in own callback and synchronous delivery', () => {
  const hub: Hub<{ event: object }> = createHub();
  const order: string[] = [];
  let remove = () => {};
  remove = hub.subscribe('event', () => { order.push('callback'); remove(); assert.equal(hub.listenerCount('event'), 0); });
  order.push('before'); assert.equal(hub.publish('event', {}), undefined); order.push('after');
  hub.publish('event', {}); assert.deepEqual(order, ['before', 'callback', 'after']);
});

test('monitor clients preserve strict threshold and active registration counts', () => {
  const hub = createHub<MonitorEvents>();
  const removeRule = attachAlarmRule(hub, 10);
  const collector = collectAlarms(hub);
  hub.publish('reading', { sensor: 'cold', value: 10 });
  hub.publish('reading', { sensor: 'warm', value: 11 });
  assert.deepEqual(collector.alarms, [{ sensor: 'warm', value: 11, limit: 10 }]);
  assert.equal(hub.listenerCount('reading'), 1); assert.equal(hub.listenerCount('alarm'), 1);
  collector.stop(); collector.stop(); hub.publish('reading', { sensor: 'hot', value: 20 });
  assert.equal(collector.alarms.length, 1); assert.equal(hub.listenerCount('alarm'), 0);
  removeRule(); removeRule(); assert.equal(hub.listenerCount('reading'), 0);
});
