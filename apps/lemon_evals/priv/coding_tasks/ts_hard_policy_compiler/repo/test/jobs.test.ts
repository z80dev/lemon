import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/jobs/vocabulary.ts';
test('jobs old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/jobs/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('jobs',[layer],{[v.path]:'jobs/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
