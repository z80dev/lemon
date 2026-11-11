import test from 'node:test';
import assert from 'node:assert/strict';
import { runJobs } from '../src/pool.ts';
test('single slot serializes even synchronous failures and preserves order', async()=>{
  const events:number[]=[];
  const jobs=[0,1,2].map(i=>({key:'account',run:()=>{events.push(i);if(i===1)throw 'bad';return i;}}));
  assert.deepEqual(await runJobs(jobs,{concurrency:1}),[{status:'fulfilled',value:0},{status:'rejected',reason:'bad'},{status:'fulfilled',value:2}]);
  assert.deepEqual(events,[0,1,2]);
});
test('preaborted work never starts',async()=>{
  const c=new AbortController();c.abort('closed');
  assert.deepEqual(await runJobs([{key:'a',run:()=>assert.fail('started')}],{concurrency:1,signal:c.signal}),[{status:'aborted',reason:'closed'}]);
});
