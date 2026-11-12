import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/billing/vocabulary.ts';
test('billing old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/billing/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('billing',[layer],{[v.path]:'billing/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
