import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('identity legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/identity/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('identity',raw,['y'],{x:10}),{y:10});
});
