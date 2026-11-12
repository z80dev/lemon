import test from 'node:test';
import assert from 'node:assert/strict';
import { getEventListeners } from 'node:events';
import { runJobs } from '../src/pool.ts';
import { exportRecords } from '../src/exports.ts';
const deferred = () => { let resolve!: (x: any) => void; let reject!: (x: any) => void; const promise = new Promise<any>((a,b) => {resolve=a;reject=b}); return {promise,resolve,reject}; };
const flush = async () => { for (let i=0;i<20;i++) await Promise.resolve(); };
test('limit, per-key exclusion, earliest eligible, and input-order outcomes', async () => {
  const gates = Array.from({length:5},deferred); const started: number[] = [];
  const jobs = ['a','a','b','c','a'].map((key,i) => Object.freeze({key,run: (signal: AbortSignal) => {assert.equal(signal.aborted,false);started.push(i);return gates[i].promise;}}));
  const pending = runJobs(Object.freeze(jobs) as any,{concurrency:2});
  await flush(); assert.deepEqual(started,[0,2]);
  gates[2].resolve('B'); await flush(); assert.deepEqual(started,[0,2,3]);
  gates[0].resolve('A'); await flush(); assert.deepEqual(started,[0,2,3,1]);
  const failure={why:'bad'}; gates[1].reject(failure); await flush(); assert.deepEqual(started,[0,2,3,1,4]);
  gates[4].resolve('A3'); gates[3].resolve('C');
  assert.deepEqual(await pending,[{status:'fulfilled',value:'A'},{status:'rejected',reason:failure},{status:'fulfilled',value:'B'},{status:'fulfilled',value:'C'},{status:'fulfilled',value:'A3'}]);
});
test('abort cancels only pending jobs, awaits active, passes identical signal, and cleans listener', async () => {
  const controller=new AbortController(); const first=deferred(); const second=deferred(); const started: number[]=[];
  const jobs=['a','b','c','a'].map((key,i)=>({key,run:(signal: AbortSignal)=>{assert.equal(signal,controller.signal); started.push(i); return i===0?first.promise:second.promise;}}));
  const pending=runJobs(jobs,{concurrency:2,signal:controller.signal}); let done=false; pending.then(()=>{done=true});
  await flush(); controller.abort('stop'); await flush(); assert.equal(done,false); assert.deepEqual(started,[0,1]);
  first.resolve('kept'); await flush(); assert.equal(done,false); second.reject('active failed');
  assert.deepEqual(await pending,[{status:'fulfilled',value:'kept'},{status:'rejected',reason:'active failed'},{status:'aborted',reason:'stop'},{status:'aborted',reason:'stop'}]);
  assert.equal(getEventListeners(controller.signal,'abort').length,0);
});
test('preabort, invalid concurrency, throws, thenables, empty input',async()=>{
  const c=new AbortController(); const why=new Error('closed'); c.abort(why); let calls=0;
  const jobs=[{key:'x',run:()=>{calls++;return 1}}];
  assert.deepEqual(await runJobs(jobs,{concurrency:1,signal:c.signal}),[{status:'aborted',reason:why}]);
  for(const concurrency of [0,-1,1.5,NaN,Infinity]) await assert.rejects(runJobs(jobs,{concurrency}),RangeError);
  await assert.rejects(runJobs([],{concurrency:0}),RangeError); assert.equal(calls,0);
  assert.deepEqual(await runJobs([],{concurrency:1,signal:c.signal}),[]);
  const boom={code:9}; const controller=new AbortController();
  assert.deepEqual(await runJobs<any>([{key:'x',run:()=>{throw boom}},{key:'x',run:()=>({then(resolve:any){resolve(7)}})},{key:'z',run:()=>9}],{concurrency:1,signal:controller.signal}),[{status:'rejected',reason:boom},{status:'fulfilled',value:7},{status:'fulfilled',value:9}]);
  assert.equal(getEventListeners(controller.signal,'abort').length,0);
});
test('abort during invocation cannot launch the next job; exports report canceled separately', async()=>{
  const c=new AbortController(); const g=deferred(); const records=['1','2','3','4'].map((id,i)=>({id,account:i===1?'a':'b',contents:''}));
  const report=exportRecords(records,(record,signal)=>{assert.equal(signal,c.signal); if(record.id==='1') return g.promise; if(record.id==='2'){c.abort('halt');throw 'bad';} throw new Error('must not start');},{concurrency:2,signal:c.signal});
  g.resolve('receipt');
  assert.deepEqual(await report,{receipts:['receipt'],failed:['2'],skipped:['3','4']});
});
