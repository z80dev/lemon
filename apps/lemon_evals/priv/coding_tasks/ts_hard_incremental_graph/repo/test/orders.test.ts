import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('orders legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/orders/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('orders',raw,['y'],{x:16}),{y:16});
});
