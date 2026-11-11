import test from 'node:test';
import assert from 'node:assert/strict';
import { exportRecords } from '../src/exports.ts';
test('successful records retain input ordering', async () => {
  const records = [{id:'1',account:'a',contents:'x'}, {id:'2',account:'b',contents:'y'}];
  assert.deepEqual(await exportRecords(records, async record => `saved:${record.id}`, {concurrency:2}), {receipts:['saved:1','saved:2'],failed:[],skipped:[]});
});
