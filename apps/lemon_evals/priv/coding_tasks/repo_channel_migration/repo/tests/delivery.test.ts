import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig, message, dispatch, plan, metricKey } from '../src/index.ts';
test('delivery plans preserve input order and sms limits', () => {
  const config = loadConfig({ deliveryChannel: 'sms', batchSize: 25 });
  const items = Array.from({ length: 11 }, (_, i) => message(String(i), '+15551234567', 'hi'));
  assert.deepEqual(plan(config, items).batches.map(x => x.length), [10, 1]);
  assert.deepEqual(dispatch(config, items).map(x => x.id), items.map(x => x.id));
  assert.equal(metricKey(config, 'clinic'), 'dispatch.clinic.sms');
  assert.throws(() => dispatch(config, [message('x', '+15551234567', 'a'.repeat(161))]), /160/);
});
test('webhook renders payload', () => {
  const output = plan(loadConfig({ deliveryChannel: 'webhook' }), [message('w', 'https://example.test', 'hello')]);
  assert.deepEqual(JSON.parse(output.batches[0][0].body), { id: 'w', text: 'hello' });
});
