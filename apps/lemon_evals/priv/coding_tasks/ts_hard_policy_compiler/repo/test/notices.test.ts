import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/notices/vocabulary.ts';
test('notices old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/notices/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('notices',[layer],{[v.path]:'notices/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
