import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/payments/vocabulary.ts';
test('payments old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/payments/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('payments',[layer],{[v.path]:'payments/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
