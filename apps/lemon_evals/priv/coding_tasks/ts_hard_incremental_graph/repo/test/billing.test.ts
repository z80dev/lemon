import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('billing legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/billing/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('billing',raw,['y'],{x:3}),{y:3});
});
