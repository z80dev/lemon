import test from 'node:test';
import assert from 'node:assert/strict';
import { EventBus } from '../src/index.ts';
test('dispatch deduplicates and snapshots isolate state', () => {
  const bus = new EventBus();
  const request = { tenantId: 't', actorId: 'a', key: 'k', topic: 'invoice.issued', payload: { cents: 100 } };
  assert.deepEqual(bus.dispatch(request), { id: 'evt-1', accepted: true });
  request.payload.cents = 900;
  assert.deepEqual(bus.dispatch(request), { id: 'evt-1', accepted: false });
  assert.equal(bus.snapshot()[0].payload.cents, 100);
  assert.equal(bus.size, 1);
});

test('retired API is absent', () => { assert.equal('publish' in new EventBus(), false); });
