import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig, tenantConfig, serializeConfig, fromEnvironment } from '../src/index.ts';
test('defaults, environment and tenant settings', () => {
  assert.deepEqual(loadConfig(), { deliveryChannel: 'email', batchSize: 25, sender: 'harbor' });
  const config = fromEnvironment({ HARBOR_DELIVERY_CHANNEL: 'sms', HARBOR_SENDER: ' clinic ' });
  assert.equal(tenantConfig(config, { batchSize: 8 }).deliveryChannel, 'sms');
  assert.equal(config.sender, 'clinic');
  assert.equal(JSON.parse(serializeConfig(config)).deliveryChannel, 'sms');
});
test('invalid config rejected', () => {
  assert.throws(() => loadConfig({ batchSize: 0 }), /batchSize/);
  assert.throws(() => loadConfig({ sender: ' ' }), /sender/);
});
