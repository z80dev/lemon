import test from 'node:test';
import assert from 'node:assert/strict';
import { options } from '../src/cli/options.ts';
test('CLI options choose a usable default destination', () => {
  assert.equal(options(['--channel', 'sms']).recipient, '+15551234567');
  assert.throws(() => options(['--typo', 'x']), /unsupported flag/);
  assert.throws(() => options(['--message']), /missing value/);
});
