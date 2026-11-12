import test from 'node:test';
import assert from 'node:assert/strict';
import { createHub } from '../src/hub.ts';
import { attachAlarmRule, collectAlarms } from '../src/monitor.ts';
import type { MonitorEvents } from '../src/monitor.ts';

test('monitor rules and collectors have independent lifetimes', () => {
  const hub = createHub<MonitorEvents>();
  const stopRule = attachAlarmRule(hub, 20);
  const collector = collectAlarms(hub);
  hub.publish('reading', { sensor: 'boiler', value: 20 });
  hub.publish('reading', { sensor: 'boiler', value: 21 });
  assert.deepEqual(collector.alarms, [{ sensor: 'boiler', value: 21, limit: 20 }]);
  stopRule(); stopRule();
  hub.publish('reading', { sensor: 'boiler', value: 99 });
  assert.equal(collector.alarms.length, 1);
  collector.stop();
  assert.equal(hub.listenerCount('alarm'), 0);
});

test('once is consumed before recursive publishing', () => {
  const hub = createHub<{ tick: number }>();
  const seen: number[] = [];
  hub.subscribe('tick', number => { seen.push(number); if (number === 1) hub.publish('tick', 2); }, { once: true });
  hub.publish('tick', 1);
  assert.deepEqual(seen, [1]);
  assert.equal(hub.listenerCount('tick'), 0);
});
