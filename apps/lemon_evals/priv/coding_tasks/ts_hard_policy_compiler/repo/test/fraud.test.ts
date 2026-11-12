import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/fraud/vocabulary.ts';
test('fraud old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/fraud/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('fraud',[layer],{[v.path]:'fraud/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
