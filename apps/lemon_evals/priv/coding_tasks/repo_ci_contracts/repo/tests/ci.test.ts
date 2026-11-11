import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
test('CI source and route contracts are clean',()=>{
  const result=spawnSync(process.execPath,['scripts/ci.ts'],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);assert.equal(result.stdout,'contracts: ok\n');
});
