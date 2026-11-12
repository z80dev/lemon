import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Graph} from '../src/graph.ts';

test('graph caches, replaces atomically and owns snapshots',()=>{
  const nodes=[{id:'a',deps:[],kind:'input' as const},
    {id:'out',deps:['a'],kind:'offset' as const,value:3}];
  const graph=new Graph(nodes);
  assert.deepEqual(graph.evaluate(['out'],{a:2}),{values:{out:5},executed:['a','out']});
  nodes[1].value=999;
  assert.deepEqual(graph.evaluate(['out'],{a:2}).executed,[]);
  assert.equal(graph.evaluate(['out'],{a:2}).values.out,5);
  assert.throws(()=>graph.replace([{id:'cycle',deps:['cycle'],kind:'sum'}]));
  assert.deepEqual(graph.evaluate(['out'],{a:2}).executed,[]);
  graph.replace([{id:'a',deps:[],kind:'input'},{id:'out',deps:['a'],kind:'offset',value:4}]);
  assert.deepEqual(graph.evaluate(['out'],{a:2}),{values:{out:6},executed:['out']});
});
