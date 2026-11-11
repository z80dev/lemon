import test from 'node:test';
import assert from 'node:assert/strict';
import { EventBus, topicCounts, tenantEvents } from '../src/index.ts';
test('projections retain tenant isolation', () => {
  const bus = new EventBus();
  for(const tenantId of ['one','two']) bus.dispatch({ tenantId, actorId:'a', key:'k', topic:'order.submitted', payload:{} });
  assert.deepEqual(topicCounts(bus.snapshot()), {'order.submitted':2});
  assert.equal(tenantEvents(bus.snapshot(),'one').length, 1);
});
