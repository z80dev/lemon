import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('keys legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/keys/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('keys',raw,['y'],{x:12}),{y:12});
});
