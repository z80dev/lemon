import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/hosting/vocabulary.ts';
test('hosting old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/hosting/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('hosting',[layer],{[v.path]:'hosting/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
