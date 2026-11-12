import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('hosting legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/hosting/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('hosting',raw,['y'],{x:9}),{y:9});
});
