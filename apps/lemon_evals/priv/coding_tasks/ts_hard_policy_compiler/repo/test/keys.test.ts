import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/keys/vocabulary.ts';
test('keys old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/keys/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('keys',[layer],{[v.path]:'keys/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
