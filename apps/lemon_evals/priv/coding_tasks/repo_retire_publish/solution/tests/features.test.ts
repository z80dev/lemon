import test from 'node:test';
import assert from 'node:assert/strict';
import { EventBus, context, issueInvoice, reserveInventory, inviteMember } from '../src/index.ts';
test('billing, stock and membership produce normalized events', () => {
  const bus = new EventBus(); const ctx = context('shop', 'staff', 'req');
  assert.deepEqual(issueInvoice(bus, ctx, { invoiceId: ' i ', cents: 125 }), { id: 'evt-1', accepted: true });
  assert.deepEqual(issueInvoice(bus, ctx, { invoiceId: ' i ', cents: 125 }), { id: 'evt-1', accepted: false });
  reserveInventory(bus, ctx, { sku: ' low ', quantity: 2 });
  inviteMember(bus, ctx, { email: ' A@Example.test ', role: ' EDITOR ' });
  assert.deepEqual(bus.snapshot().map(e => e.payload), [{ invoiceId: 'i', cents: 125, currency: 'USD' }, { sku: 'LOW', quantity: 2 }, { email: 'a@example.test', role: 'editor' }]);
});
test('invalid feature input does not append', () => {
  const bus = new EventBus();
  assert.throws(() => issueInvoice(bus, context('t','a','r'), { invoiceId:'i', cents:0 }), /positive integer/);
  assert.equal(bus.size, 0);
});
