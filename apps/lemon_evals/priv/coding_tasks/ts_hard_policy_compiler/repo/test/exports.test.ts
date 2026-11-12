import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {check} from '../src/api.ts';
import {vocabulary as v} from '../gateways/exports/vocabulary.ts';
test('exports old allow rule',()=>{
 const layer=JSON.parse(readFileSync(new URL('../gateways/exports/sample.json',import.meta.url),'utf8'));
 assert.deepEqual(check('exports',[layer],{[v.path]:'exports/items',[v.action]:'read'}),{allowed:true,ruleId:'reader'});
});
