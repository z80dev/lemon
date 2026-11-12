import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('assets legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/assets/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('assets',raw,['y'],{x:2}),{y:2});
});
