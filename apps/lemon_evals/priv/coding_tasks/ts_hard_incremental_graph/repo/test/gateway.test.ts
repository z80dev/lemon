import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('gateway legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/gateway/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('gateway',raw,['y'],{x:8}),{y:8});
});
