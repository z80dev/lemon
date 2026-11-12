import {test} from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {Policy}=await import(pathToFileURL(process.cwd()+'/src/policy.ts').href);
const api=await import(pathToFileURL(process.cwd()+'/src/api.ts').href);
assert.deepEqual([...api.gateways].sort(),['assets','billing','catalog','delivery','exports','fraud','gateway','hosting','identity','jobs','keys','logging','metrics','notices','orders','payments'].sort());
const arenaHiddenRule=(id:string,resource='docs/**',effect='allow',priority=0,conditions={})=>({id,resource,effect,priority,actions:['read'],conditions});
const arenaHiddenRequest=(resource='docs/team/a',attributes={})=>({resource,action:'read',attributes});
const arenaHiddenLayer=(rules:any[],name='base',remove:string[]=[])=>({name,rules,remove});
test('ArenaHiddenPolicy overlays ranking wildcards and conditions',()=>{
 const layers=[arenaHiddenLayer([
  arenaHiddenRule('wide'),arenaHiddenRule('specific','docs/team/*'),
  arenaHiddenRule('deny','docs/team/*','deny'),arenaHiddenRule('admin','docs/**','allow',10,{role:['admin','owner'],blocked:null}),
  arenaHiddenRule('deleted','docs/**','deny',99)
 ]),arenaHiddenLayer([arenaHiddenRule('specific','docs/team/*','allow')],'overlay',['deleted'])];
 const policy=new Policy(layers);layers[0].rules[0].effect='deny';
 assert.deepEqual(policy.explain(arenaHiddenRequest()),['deny','specific','wide']);
 assert.deepEqual(policy.decide(arenaHiddenRequest()),{allowed:false,ruleId:'deny'});
 assert.deepEqual(policy.decide(arenaHiddenRequest('docs/team/a',{role:'admin'})),{allowed:true,ruleId:'admin'});
 assert.equal(policy.decide(arenaHiddenRequest('docs/team/a',{role:'admin',blocked:''})).ruleId,'deny');
 assert.equal(policy.decide(arenaHiddenRequest('docs')).ruleId,'wide');
 assert.equal(policy.decide(arenaHiddenRequest('other')).ruleId,null);
 const inherited=Object.create({role:'admin'});
 assert.equal(policy.decide(arenaHiddenRequest('docs/team/a',inherited)).ruleId,'deny');
 const snapshot=policy.exportLayers();snapshot[0].rules[0].id='mutated';
 assert.equal(policy.exportLayers()[0].rules[0].id,'wide');
 assert.throws(()=>policy.replace([arenaHiddenLayer([arenaHiddenRule('x','bad/**/path')])]));
 assert.equal(policy.decide(arenaHiddenRequest()).ruleId,'deny');
 const round=new Policy(policy.exportLayers());assert.deepEqual(round.explain(arenaHiddenRequest()),policy.explain(arenaHiddenRequest()));
 policy.replace([]);assert.deepEqual(policy.decide(arenaHiddenRequest()),{allowed:false,ruleId:null});
 const tie=new Policy([arenaHiddenLayer([arenaHiddenRule('z'),arenaHiddenRule('a')])]);assert.equal(tie.decide(arenaHiddenRequest()).ruleId,'a');
 const removed=new Policy([arenaHiddenLayer([arenaHiddenRule('a')]),arenaHiddenLayer([arenaHiddenRule('a','docs/**','deny')],'next',['a'])]);
 assert.equal(removed.decide(arenaHiddenRequest()).allowed,false);
});
test('ArenaHiddenPolicy rejects malformed even shadowed rules',()=>{
 const base=arenaHiddenRule('x');
 for(const bad of [{...base,resource:'a//b'},{...base,resource:'a/pre*'}, {...base,actions:[]},{...base,actions:['read','read']},
 {...base,priority:1.2},{...base,conditions:{x:[]}},{...base,conditions:{x:['a','a']}},{...base,effect:'maybe'}, {...base,extra:true}]){
  assert.throws(()=>new Policy([arenaHiddenLayer([bad]),arenaHiddenLayer([base],'later')]));
 }
 assert.throws(()=>new Policy([arenaHiddenLayer([base,base])]));
 assert.throws(()=>new Policy([arenaHiddenLayer([]),arenaHiddenLayer([])]));
 assert.throws(()=>new Policy([arenaHiddenLayer([],'base',['x','x'])]));
 const policy=new Policy([]);
 for(const request of [null,{}, {...arenaHiddenRequest(),extra:1},arenaHiddenRequest('docs/*'),arenaHiddenRequest('/docs'),arenaHiddenRequest('docs',{x:3}),{...arenaHiddenRequest(),action:''}]) assert.throws(()=>policy.decide(request));
 const wildcard=new Policy([arenaHiddenLayer([{...base,resource:'docs/*',actions:['*'],conditions:{empty:''}}])]);
 assert.equal(wildcard.decide({resource:'docs/a',action:'write',attributes:{empty:''}}).allowed,true);
 assert.equal(wildcard.decide({resource:'docs/a/b',action:'write',attributes:{empty:''}}).allowed,false);
});
test('ArenaHiddenPolicy all gateway boundaries',async()=>{
 for(const name of api.gateways){
  const {vocabulary:v}=await import(pathToFileURL(process.cwd()+`/gateways/${name}/vocabulary.ts`).href);
  for(const key of ['layer','rules','remove','id','effect','path','actions','priority','conditions','action','attributes']) assert.equal(v[key],name+'_'+key);
  assert.equal(v.defaultResource,name+'/items');
  const codec=await import(pathToFileURL(process.cwd()+`/gateways/${name}/codec.ts`).href);
  const wireRule=(id:string,effect:string,priority:number)=>({[v.id]:id,[v.effect]:effect,[v.path]:name+'/**',[v.actions]:['read'],[v.priority]:priority,[v.conditions]:{role:['admin']}});
  const raw=[{[v.layer]:'base',[v.rules]:[wireRule('allow','allow',0),wireRule('deny','deny',1)]}];
  const request={[v.path]:name+'/a',[v.action]:'read',[v.attributes]:{role:'admin'}};
  const before=JSON.stringify(raw),gateway=api.create(name,raw);
  assert.deepEqual(gateway.authorize(request),{allowed:false,ruleId:'deny'});
  assert.deepEqual(gateway.explain(request),['deny','allow']);
  assert.equal(JSON.stringify(raw),before);
  assert.throws(()=>gateway.reload([{[v.layer]:'broken',[v.rules]:[{}]}]));
  assert.equal(gateway.authorize(request).ruleId,'deny');
  gateway.reload([...raw,{[v.layer]:'remove',[v.rules]:[],[v.remove]:['deny']}]);
  assert.deepEqual(gateway.authorize(request),{allowed:true,ruleId:'allow'});
  const snapshot=gateway.snapshot();snapshot[0].rules[0].conditions.role.push('hacker');
  assert.equal(gateway.authorize({...request,[v.attributes]:{role:'hacker'}}).allowed,false);
  assert.deepEqual(api.check(name,raw,request),{allowed:false,ruleId:'deny'});
  assert.throws(()=>codec.decodeLayer({[v.layer]:'bad',[v.rules]:[wireRule('x','allow',1),wireRule('x','deny',2)]}));
  assert.throws(()=>codec.decodeRequest({[v.action]:'read'}));
  assert.deepEqual(codec.decodeRequest({[v.path]:name+'/a',[v.action]:'read'}).attributes,{});
 }
 assert.throws(()=>api.create('unknown',[]));
});
