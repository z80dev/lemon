import test from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root=process.cwd();
const api=await import(pathToFileURL(join(root,'src/index.ts')).href);
const mappings=JSON.parse(readFileSync(new URL('./features.json',import.meta.url),'utf8'));
test('retired exports, methods, types and instructions are absent', async () => {
  const bus=new api.EventBus();
  assert.equal('publish' in bus,false); assert.equal('publish' in api,false);
  const busApi=await import(pathToFileURL(join(root,'src/bus.ts')).href);
  assert.equal('publish' in busApi,false);
  function walk(dir) { return readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(join(dir,e.name)):[join(dir,e.name)]); }
  for(const file of walk(join(root,'src'))) if(file.endsWith('.ts')) assert.doesNotMatch(readFileSync(file,'utf8'),/\bpublish\b|\bLegacyPublisher\b/,file);
  assert.doesNotMatch(readFileSync(join(root,'README.md'),'utf8'),/\bpublish\b|\bLegacyPublisher\b/);
  assert.match(readFileSync(join(root,'src/index.ts'),'utf8'),/\bDispatchTarget\b/);
});
test('all fifteen feature paths dispatch exact normalized envelopes and receipts', () => {
  const bus=new api.EventBus(); const context={tenantId:'tenant-one',actorId:'operator',requestId:'operation'};
  for(const [index,m] of mappings.entries()) {
    const receipt=api[m.fn](bus,context,structuredClone(m.input));
    assert.deepEqual(receipt,{id:`evt-${index+1}`,accepted:true},m.fn);
    assert.deepEqual(api[m.fn](bus,context,structuredClone(m.input)),{...receipt,accepted:false},m.fn);
    assert.deepEqual(bus.snapshot()[index],{id:receipt.id,tenantId:'tenant-one',actorId:'operator',key:'operation',topic:m.topic,payload:m.payload},m.fn);
    let observed;
    const target={dispatch(request){observed=request;return {id:'external',accepted:false};}};
    assert.deepEqual(api[m.fn](target,context,m.input),{id:'external',accepted:false},m.fn);
    assert.deepEqual(observed,{tenantId:'tenant-one',actorId:'operator',key:'operation',topic:m.topic,payload:m.payload},m.fn);
    const invalid=structuredClone(m.input); const field=Object.keys(invalid)[0]; invalid[field]=' ';
    assert.throws(()=>api[m.fn](bus,context,invalid),/must be nonempty/,m.fn);
  }
  assert.equal(bus.size,15);
  const first=mappings[0]; assert.equal(api[first.fn](bus,{...context,tenantId:'tenant-two'},first.input).accepted,true);
  assert.equal(bus.size,16);
  assert.deepEqual(api.topicCounts(bus.snapshot()),Object.fromEntries(mappings.map((m,i)=>[m.topic,i===0?2:1])));
  assert.equal(api.tenantEvents(bus.snapshot(),'tenant-one').length,15);
});
test('dispatch validates before dedupe and maintains snapshot isolation', () => {
  const bus=new api.EventBus();
  const request={tenantId:'t',actorId:'a',key:'k',topic:'order.submitted',payload:{nested:{value:1}}};
  assert.deepEqual(bus.dispatch(request),{id:'evt-1',accepted:true});
  request.payload.nested.value=9;
  const snapshot=bus.snapshot(); snapshot[0].payload.nested.value=8;
  assert.equal(bus.snapshot()[0].payload.nested.value,1);
  for(const field of ['tenantId','actorId','key','topic']) assert.throws(()=>bus.dispatch({...request,[field]:' '}),{message:`${field} must be nonempty`});
  assert.throws(()=>bus.dispatch({...request,topic:'Bad'}),/dotted lowercase/);
  for(const payload of [null,[],1]) assert.throws(()=>bus.dispatch({...request,payload}),/payload must be an object/);
  assert.equal(bus.size,1);
  assert.deepEqual(bus.dispatch({...request,topic:'invoice.issued'}),{id:'evt-2',accepted:true});
  const run=spawnSync(process.execPath,['scripts/demo.ts'],{cwd:root,encoding:'utf8'});
  assert.equal(run.status,0,run.stderr);
  const result=JSON.parse(run.stdout);
  assert.deepEqual(result.invoiceReceipt,{id:'evt-1',accepted:true}); assert.deepEqual(result.inviteReceipt,{id:'evt-2',accepted:true});
});
