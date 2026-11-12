import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('logging legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/logging/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('logging',raw,['y'],{x:13}),{y:13});
});
