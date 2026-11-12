import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/identity/vocabulary.ts';
test('identity old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/identity/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('identity',[layer],{[v.path]:'identity/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
