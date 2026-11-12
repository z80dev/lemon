import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('delivery legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/delivery/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('delivery',raw,['y'],{x:5}),{y:5});
});
