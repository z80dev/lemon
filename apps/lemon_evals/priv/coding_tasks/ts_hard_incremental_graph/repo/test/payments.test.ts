import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('payments legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/payments/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('payments',raw,['y'],{x:17}),{y:17});
});
