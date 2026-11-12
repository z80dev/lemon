import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/catalog/vocabulary.ts';
test('catalog old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/catalog/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('catalog',[layer],{[v.path]:'catalog/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
