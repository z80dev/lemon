import test from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = process.cwd();
const api = await import(pathToFileURL(join(root, 'src/index.ts')).href);
const { options } = await import(pathToFileURL(join(root, 'src/cli/options.ts')).href);
test('canonical key only, strict tenant overrides, environment and persistence', () => {
  assert.deepEqual(api.loadConfig(), { channel: 'email', batchSize: 25, sender: 'harbor' });
  for (const input of [{ deliveryChannel: 'sms' }, { channel: 'sms', deliveryChannel: 'email' }])
    assert.throws(() => api.loadConfig(input), { message: 'unsupported config key: deliveryChannel' });
  assert.throws(() => api.tenantConfig(api.loadConfig(), { deliveryChannel: 'sms' }), /unsupported config key/);
  assert.throws(() => api.loadConfig({ channel: 'push' }), { message: 'channel must be email, sms or webhook' });
  for (const batchSize of [0, 101, 1.5]) assert.throws(() => api.loadConfig({ batchSize }), /batchSize/);
  assert.throws(() => api.loadConfig({ sender: '' }), /sender/);
  const config = api.fromEnvironment({ HARBOR_CHANNEL: 'webhook', HARBOR_DELIVERY_CHANNEL: 'sms', HARBOR_BATCH_SIZE: '9', HARBOR_SENDER: ' ops ' });
  assert.deepEqual(config, { channel: 'webhook', batchSize: 9, sender: 'ops' });
  assert.equal(api.fromEnvironment({ HARBOR_DELIVERY_CHANNEL: 'sms' }).channel, 'email');
  assert.deepEqual(api.tenantConfig(config, { channel: 'sms' }), { ...config, channel: 'sms' });
  assert.equal(api.serializeConfig(config), JSON.stringify(config, null, 2) + '\n');
  const dir = mkdtempSync(join(tmpdir(), 'harbor-'));
  try { const path=join(dir, 'config.json'); api.saveConfig(path, config); assert.deepEqual(api.readConfig(path), config); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});
test('all channel consumers, batches, bodies, receipts and metrics', () => {
  const destinations = { email: 'a@b.test', sms: '+15551234567', webhook: 'https://example.test/hook' };
  const policies = { email: { attempts: 3, delayMs: 2000 }, sms: { attempts: 2, delayMs: 5000 }, webhook: { attempts: 5, delayMs: 1000 } };
  for (const channel of ['email', 'sms', 'webhook']) {
    const config=api.loadConfig({ channel, batchSize: 11, sender: 'team' });
    const items=Array.from({ length: 12 }, (_, n) => api.message(String(n), destinations[channel], 'hello'));
    const plan=api.plan(config, items);
    assert.equal(plan.channel, channel); assert.deepEqual(plan.retry, policies[channel]);
    assert.deepEqual(plan.batches.map(x=>x.length), channel==='sms' ? [10,2] : [11,1]);
    const envelope=plan.batches[0][0];
    assert.equal(envelope.channel, channel); assert.equal(envelope.sender, 'team');
    assert.equal(envelope.body, channel==='sms' ? 'hello' : channel==='email' ? 'Subject: Harbor update\n\nhello' : '{"id":"0","text":"hello"}');
    assert.deepEqual(api.dispatch(config, items), items.map(item=>({ id:item.id, channel, status:'queued', destination:item.recipient })));
    assert.equal(api.metricKey(config, 'team'), `dispatch.team.${channel}`);
    assert.throws(()=>api.dispatch(config,[api.message('bad','invalid','hello')]), { message:`invalid ${channel} destination` });
  }
  assert.throws(()=>api.dispatch(api.loadConfig({channel:'sms'}),[api.message('long','+15551234567','x'.repeat(161))]), /160/);
  assert.deepEqual(api.plan(api.loadConfig(), []).batches, []);
});
test('scripts and operational JSON use canonical inputs', () => {
  assert.throws(()=>options(['--delivery-channel','sms']), /unsupported flag/);
  for(const channel of ['email','sms','webhook']) {
    const run=spawnSync(process.execPath,['scripts/dispatch.ts','--channel',channel,'--message','hello'],{cwd:root,encoding:'utf8'});
    assert.equal(run.status,0,run.stderr); assert.equal(JSON.parse(run.stdout)[0].channel,channel);
  }
  const run=spawnSync(process.execPath,['scripts/export-config.ts'],{cwd:root,encoding:'utf8',env:{...process.env,HARBOR_CHANNEL:'sms'}});
  assert.equal(run.status,0,run.stderr); assert.equal(JSON.parse(run.stdout).channel,'sms');
  function walk(dir) { return readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(join(dir,e.name)):[join(dir,e.name)]); }
  for(const dir of ['src','scripts','config']) for(const path of walk(join(root,dir))) {
    const text=readFileSync(path,'utf8');
    assert.doesNotMatch(text,/deliveryChannel|HARBOR_DELIVERY_CHANNEL|--delivery-channel/,path);
    if(path.endsWith('.json')) assert.ok('channel' in JSON.parse(text),path);
  }
  assert.doesNotMatch(readFileSync(join(root,'README.md'),'utf8'),/deliveryChannel|HARBOR_DELIVERY_CHANNEL|--delivery-channel/);
});
