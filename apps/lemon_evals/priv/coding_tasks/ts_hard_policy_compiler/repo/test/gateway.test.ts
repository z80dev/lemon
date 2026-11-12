import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/gateway/vocabulary.ts';
test('gateway old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/gateway/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('gateway',[layer],{[v.path]:'gateway/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
