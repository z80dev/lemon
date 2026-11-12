import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp, createContext } from '../src/index.ts';
test('health and stock routes have distinct contracts', () => {
  const app = createApp(); const ctx = createContext();
  assert.deepEqual(app.handle({ method: 'GET', path: '/v1/health' }, ctx), { status: 200, body: { ok: true } });
  assert.deepEqual(app.handle({ method: 'GET', path: '/v1/stock' }, ctx), { status: 200, body: { items: [] } });
  assert.deepEqual(app.handle({ method: 'POST', path: '/v1/reservations', body: { reservationId:'r', sku:'x', quantity:1 } }, ctx), {status:401,body:{error:'unauthorized',message:'actor required'}});
});
test('quantity must be integer and insufficient stock is a conflict', () => {
  const app = createApp(); const ctx = createContext('operator', () => 42);
  assert.equal(app.handle({ method:'POST',path:'/v1/stock',body:{sku:'x',quantity:1.5}},ctx).status,400);
  app.handle({method:'POST',path:'/v1/stock',body:{sku:'x',quantity:2}},ctx);
  assert.deepEqual(app.handle({method:'POST',path:'/v1/reservations',body:{reservationId:'r',sku:'x',quantity:3}},ctx),{status:409,body:{error:'conflict',message:'insufficient stock'}});
});
