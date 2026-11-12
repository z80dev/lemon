import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('exports legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/exports/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('exports',raw,['y'],{x:6}),{y:6});
});
