import test from 'node:test';
import assert from 'node:assert/strict';
import * as cli from '../src/cli.ts';
import * as http from '../src/http.ts';
import { describeCommands } from '../src/batch.ts';
import { resolveCommand, executeCommand } from '../src/commands.ts';
test('registry resolution is shared, canonical, and independently owned', () => {
  for (const [canonical, aliases, mutating] of [['list',['list','ls'],false],['show',['show','get'],false],['delete',['delete','rm'],true]] as const) {
    for (const alias of aliases) {
      const command = resolveCommand(` ${alias.toUpperCase()}\n`)!;
      assert.deepEqual(command, {name:canonical,mutating});
      assert.equal(executeCommand(command,' a:b '), canonical === 'list' ? 'items' : `${canonical === 'show' ? 'item' : 'deleted'}: a:b `);
    }
  }
  for (const s of ['', '  ', '__proto__', 'constructor', 'list x']) assert.equal(resolveCommand(s), undefined);
  const a = resolveCommand('ls')!; a.name='delete'; assert.equal(resolveCommand('ls')!.name,'list');
  assert.equal('findCommand' in cli, false); assert.equal('findCommand' in http, false);
});
test('all adapters migrate and preserve error precedence', () => {
  assert.deepEqual(describeCommands([' LS ', 'GET','rm','x','ls']), ['list','show','delete','?','list']);
  assert.deepEqual(cli.runCli([]), {code:2,output:'unknown command'});
  assert.deepEqual(cli.runCli([' LS ', 'ignored']), {code:0,output:'items'});
  for (const command of ['show','get','delete','rm']) {
    assert.deepEqual(cli.runCli([command]), {code:2,output:'missing id'});
    assert.deepEqual(cli.runCli([command,'']), {code:2,output:'missing id'});
    assert.deepEqual(cli.runCli([command,' 42 ','ignored']), {code:0,output:`${['show','get'].includes(command)?'item':'deleted'}: 42 `});
  }
  assert.deepEqual(http.dispatch({command:'missing'}), {status:404,body:'unknown command'});
  assert.deepEqual(http.dispatch({command:' RM '}), {status:403,body:'forbidden'});
  assert.deepEqual(http.dispatch({command:'rm',authorized:true}), {status:400,body:'missing id'});
  assert.deepEqual(http.dispatch({command:'GET',payload:''}), {status:400,body:'missing id'});
  const input = {command:'rm',payload:' p ',authorized:true};
  assert.deepEqual(http.dispatch(input), {status:200,body:'deleted: p '});
  assert.deepEqual(input, {command:'rm',payload:' p ',authorized:true});
  assert.deepEqual(http.dispatch({command:'Ls'}), {status:200,body:'items'});
});
