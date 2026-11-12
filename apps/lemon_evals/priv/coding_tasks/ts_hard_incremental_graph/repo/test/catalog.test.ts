import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('catalog legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/catalog/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('catalog',raw,['y'],{x:4}),{y:4});
});
