import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('jobs legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/jobs/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('jobs',raw,['y'],{x:11}),{y:11});
});
