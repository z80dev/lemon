import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Policy} from '../src/policy.ts';
import type {Rule} from '../src/policy.ts';

test('overlay removals and ranked deny survive failed replace',()=>{
  const rule:Rule={id:'allow',resource:'docs/**',actions:['read'],effect:'allow',priority:0,conditions:{}};
  const policy=new Policy([
    {name:'base',rules:[rule,{...rule,id:'deny',effect:'deny',priority:1}],remove:[]},
    {name:'overlay',rules:[],remove:['allow']}
  ]);
  const request={resource:'docs/a',action:'read',attributes:{}};
  assert.deepEqual(policy.decide(request),{allowed:false,ruleId:'deny'});
  assert.throws(()=>policy.replace([{name:'bad',rules:[{...rule,resource:'bad/**/path'}],remove:[]}]));
  assert.deepEqual(policy.explain(request),['deny']);
  const layers=policy.exportLayers();layers[0].rules[1].priority=-99;
  assert.equal(policy.exportLayers()[0].rules[1].priority,1);
  assert.deepEqual(new Policy(policy.exportLayers()).decide(request),policy.decide(request));
});
