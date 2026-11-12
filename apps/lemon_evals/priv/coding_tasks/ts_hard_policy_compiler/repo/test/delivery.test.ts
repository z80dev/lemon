import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/delivery/vocabulary.ts';
test('delivery old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/delivery/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('delivery',[layer],{[v.path]:'delivery/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
