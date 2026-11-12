import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('fraud legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/fraud/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('fraud',raw,['y'],{x:7}),{y:7});
});
