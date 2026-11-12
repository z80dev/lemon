import test from 'node:test';
import assert from 'node:assert/strict';
import { runCli } from '../src/cli.ts';
import { dispatch } from '../src/http.ts';
import { describeCommands } from '../src/batch.ts';
test('existing entry points', () => {
  assert.deepEqual(runCli(['show', '42']), {code: 0, output: 'item:42'});
  assert.deepEqual(dispatch({command:'delete', payload:'42'}), {status:403,body:'forbidden'});
  assert.deepEqual(describeCommands(['list', 'other']), ['list','?']);
});
