import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {summarize} from '../src/api.ts';
test('metrics legacy sum',()=>{
  const raw=JSON.parse(readFileSync(new URL('../products/metrics/sample.json',import.meta.url),'utf8'));
  assert.deepEqual(summarize('metrics',raw,['y'],{x:14}),{y:14});
});
