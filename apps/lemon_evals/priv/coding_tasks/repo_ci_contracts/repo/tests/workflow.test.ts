import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp, createContext } from '../src/index.ts';
test('fulfill releases reserved units and cancel is idempotent', () => {
  const app=createApp();const ctx=createContext('operator',()=>42);
  const post=(path:string,body?:Record<string,unknown>)=>app.handle({method:'POST',path,body},ctx);
  post('/v1/stock',{sku:'x',quantity:10});
  post('/v1/reservations',{reservationId:'one',sku:'x',quantity:3});
  post('/v1/reservations/one/fulfill');
  post('/v1/reservations',{reservationId:'two',sku:'x',quantity:2});
  post('/v1/reservations/two/cancel');post('/v1/reservations/two/cancel');
  assert.deepEqual(app.handle({method:'GET',path:'/v1/stock/x'},ctx),{status:200,body:{sku:'X',onHand:7,reserved:0,available:7}});
  assert.deepEqual(app.services.audit.snapshot().map(entry=>entry.at),[42,42,42,42,42]);
});
