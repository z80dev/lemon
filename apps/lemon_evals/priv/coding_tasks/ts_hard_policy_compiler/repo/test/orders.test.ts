import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/orders/vocabulary.ts';
test('orders old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/orders/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('orders',[layer],{[v.path]:'orders/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
