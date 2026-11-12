import {test} from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {Graph}=await import(pathToFileURL(process.cwd()+'/src/graph.ts').href);
const api=await import(pathToFileURL(process.cwd()+'/src/api.ts').href);
assert.deepEqual([...api.products].sort(),['assets','billing','catalog','delivery','exports','fraud','gateway','hosting','identity','jobs','keys','logging','metrics','notices','orders','payments'].sort());
const arenaHiddenNodes=()=>[
 {id:'x',deps:[],kind:'input'},{id:'y',deps:[],kind:'input'},
 {id:'sum',deps:['x','y'],kind:'sum'},{id:'product',deps:['sum','y'],kind:'product'},
 {id:'out',deps:['product'],kind:'offset',value:7}, {id:'other',deps:[],kind:'input'}];
test('ArenaHiddenGraph incremental atomic cache and replacement',()=>{
 const graph=new Graph(arenaHiddenNodes());
 assert.deepEqual(graph.evaluate(['out','out'],{x:2,y:3}),{values:{out:22},executed:['x','y','sum','product','out']});
 assert.deepEqual(graph.evaluate(['out'],{x:2,y:3}).executed,[]);
 assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,['x','y','sum','product','out']);
 assert.equal(graph.evaluate(['out'],{x:1,y:4}).values.out,27);
 const snapshot=graph.snapshot();snapshot[0].deps.push('bogus');
 assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,[]);
 assert.throws(()=>graph.replace([...arenaHiddenNodes(),{id:'bad',deps:['bad'],kind:'sum'}]));
 assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,[]);
 graph.replace(arenaHiddenNodes());assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,[]);
 const next=arenaHiddenNodes();next.find(n=>n.id==='out').value=8;graph.replace(next);
 assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,['out']);
 assert.throws(()=>graph.evaluate(['out','other'],{x:3,y:4}));
 assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,[]);
 assert.throws(()=>graph.evaluate(['out'],{x:Number.MAX_VALUE,y:Number.MAX_VALUE}));
 assert.deepEqual(graph.evaluate(['out'],{x:1,y:4}).executed,[]);
 const returned=graph.evaluate(['out'],{x:1,y:4});returned.values.out=999;returned.executed.push('x');
 assert.equal(graph.evaluate(['out'],{x:1,y:4}).values.out,28);
 assert.throws(()=>graph.evaluate(['missing'],{}));
 assert.throws(()=>graph.evaluate(['x'],Object.create({x:1})));
});
test('ArenaHiddenGraph unchanged intermediate results preserve downstream cache',()=>{
 const graph=new Graph([
  {id:'a',deps:[],kind:'input'},{id:'b',deps:[],kind:'input'},
  {id:'sum',deps:['a','b'],kind:'sum'},{id:'out',deps:['sum'],kind:'offset',value:1}
 ]);
 graph.evaluate(['out'],{a:2,b:3});
 assert.deepEqual(graph.evaluate(['out'],{a:1,b:4}),{values:{out:6},executed:['a','b','sum']});
});
test('ArenaHiddenGraph validates all graph regions',()=>{
 for(const bad of [null,[{id:'x',deps:[],kind:'wat'}],[{id:'x',deps:[],kind:'sum'}],
 [{id:'x',deps:[],kind:'input',value:0}], [{id:'x',deps:['missing'],kind:'sum'}],
 [{id:'x',deps:[],kind:'input'},{id:'x',deps:[],kind:'input'}],
 [{id:'x',deps:['y'],kind:'sum'},{id:'y',deps:['x'],kind:'sum'}],
 [{id:'x',deps:[],kind:'input'},{id:'y',deps:['x','x'],kind:'sum'}],
 [{id:'x',deps:[],kind:'input',extra:true}]]) assert.throws(()=>new Graph(bad));
});
test('ArenaHiddenGraph every product frontend',async()=>{
 for(const product of api.products){
  const {schema}=await import(pathToFileURL(process.cwd()+`/products/${product}/schema.ts`).href);
  for(const [key,value] of Object.entries({id:product+'_id',deps:product+'_needs',kind:product+'_op',amount:product+'_amount'})) assert.equal(schema[key],value);
  const {compile}=await import(pathToFileURL(process.cwd()+`/products/${product}/compiler.ts`).href);
  const wire=arenaHiddenNodes().map(n=>({[schema.id]:n.id,[schema.deps]:[...n.deps],[schema.kind]:n.kind,...('value' in n?{[schema.amount]:n.value}:{})}));
  const before=JSON.stringify(wire),frontend=api.create(product,wire);
  assert.equal(frontend.run(['out'],{x:2,y:3}).values.out,22);
  assert.deepEqual(frontend.run(['out'],{x:2,y:3}).executed,[]);
  frontend.update(wire);assert.deepEqual(frontend.run(['out'],{x:2,y:3}).executed,[]);
  assert.deepEqual(frontend.inspect(),compile(wire).sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0));
  assert.equal(JSON.stringify(wire),before);
  assert.throws(()=>frontend.update([{[schema.id]:'invalid'}]));
  assert.deepEqual(frontend.run(['out'],{x:2,y:3}).executed,[]);
  assert.deepEqual(api.summarize(product,wire,['out'],{x:2,y:3}),{out:22});
  assert.throws(()=>compile([{[schema.id]:'x',[schema.deps]:[],[schema.kind]:'input',[schema.amount]:'1'}]));
 }
 assert.throws(()=>api.create('unknown',[]));
});
