import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/assets/vocabulary.ts';
test('assets old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/assets/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('assets',[layer],{[v.path]:'assets/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
