import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/logging/vocabulary.ts';
test('logging old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/logging/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('logging',[layer],{[v.path]:'logging/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
