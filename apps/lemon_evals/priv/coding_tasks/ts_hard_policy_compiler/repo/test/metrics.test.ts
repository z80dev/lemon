import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/metrics/vocabulary.ts';
test('metrics old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/metrics/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('metrics',[layer],{[v.path]:'metrics/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
