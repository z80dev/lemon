import test from 'node:test';
import assert from 'node:assert/strict';
import { MemoryStore } from '../src/memory-store.js';
import { collectReceipts } from '../src/batch.js';
test('receipt text and ordered store events',async()=>{
  const store=new MemoryStore({orders:new Map([['o',{customerId:'c',lines:[{sku:'x',quantity:2}]}]]),customers:new Map([['c',{name:'Ada'}]]),prices:new Map([['x',125]])});
  assert.deepEqual(await collectReceipts(['o'],store),['o | Ada | 250']);
  assert.deepEqual(store.events,['open','order:o','customer:c','price:x','close']);
});
