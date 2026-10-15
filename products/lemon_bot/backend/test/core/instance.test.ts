import { describe, expect, test, vi } from 'bun:test';
import { mkdtemp, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import { authFixture } from './auth.test';
import { createInstanceRoutes } from '../../src/core/instance';
import { Router } from '../../src/core/router';
import { validateRuntimeLauncher } from '../../src/core/config';
import type { ConnectedLemonService } from '../../src/runtime/lemon';

async function fixture(launcher?:string,controlUrl?:string) {
  const f=authFixture();f.services.config.runtimeLauncher=launcher;if(controlUrl)f.services.config.controlUrl=controlUrl;
  const calls:string[]=[];const mutations:{method:string;options:unknown}[]=[];let reconnects=0;
  const dispatched=Promise.withResolvers<void>();
  const connectedListeners=new Set<()=>void>(),disconnectedListeners=new Set<()=>void>();
  const replies:Record<string,unknown>={
    status:{server:{version:'2026.10.9',build:{runtimeMode:'release-runtime',channel:'preview',commit:'abc123456789'},uptime_ms:12000,memory_mb:256.5},connections:{active:3,operators:1,nodes:2},runs:{active:1,queued:2,completed_today:4},channels:{configured:['telegram','discord'],connected:['telegram'],details:[{id:'telegram',state:'connected',lastError:null},{id:'discord',state:'error',lastError:{message:'Channel connection failed.',atMs:1791939998000}}]},providers:[{id:'anthropic',configured:true,credential:'present',default:true,lastError:null},{id:'openai',configured:true,credential:'missing',default:false,lastError:{message:'Provider authentication failed.',atMs:1791939997000}},{id:'ollama',configured:true,credential:'not_required',default:false,lastError:null}],skills:{installed:10,enabled:8},lifecycle:{restart:true,stop:true,reason:null}},
    health:{uptime_ms:12001,memory_mb:257},'sessions.active.list':{summary:{count:7}},'nodes.list':{summary:{count:3,online:2,presenceAvailable:true,truncated:false}},
    'system.restart':{accepted:true,action:'restart',acceptedAtMs:1791940000000},'system.stop':{accepted:true,action:'stop',acceptedAtMs:1791940000000}
  };
  const lemon:ConnectedLemonService={connected:true,methods:Object.keys(replies),controller:{url:f.services.config.controlUrl,state:'connected',connectedAtMs:1791940000000,lastDisconnectedAtMs:null,lastError:null,nextRetryAtMs:null,methodCount:6},async call<T>(method:string,params?:Record<string,unknown>,options?:{timeoutMs?:number;mutation?:boolean;resourceIds?:string[]}){calls.push(method);expect(options?.timeoutMs).toBe(5000);if(method.startsWith('system.')){expect(params).toEqual({});expect(options?.mutation).toBe(true);mutations.push({method,options});dispatched.resolve();}const reply=replies[method];if(reply instanceof Error)throw reply;return await reply as T;},reconnect(){reconnects++;},onConnected(listener){connectedListeners.add(listener);return()=>{connectedListeners.delete(listener);};},onDisconnected(listener){disconnectedListeners.add(listener);return()=>{disconnectedListeners.delete(listener);};},onEvent:()=>()=>{},start(){},close(){}};
  f.services.lemon=lemon;
  function disconnect(){lemon.connected=false;lemon.controller.state='reconnecting';lemon.controller.connectedAtMs=null;for(const listener of disconnectedListeners)listener();}
  function connect(atMs=1791940000001){lemon.connected=true;lemon.controller.state='connected';lemon.controller.connectedAtMs=atMs;for(const listener of connectedListeners)listener();}
  const router=new Router(f.services);router.register(createInstanceRoutes(f.services,1791939999000));
  const owner=await f.services.auth.session('owner'),admin=await f.services.auth.session('admin'),member=await f.services.auth.session('alice');
  async function request(path='/v1/instance',body?:unknown,token=owner.token){return router.fetch(new Request(`https://lemon.example${path}`,{method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})}));}
  async function status(){const response=await request();expect(response.status).toBe(200);return await response.json() as P.InstanceStatus;}
  return {...f,calls,mutations,dispatched:dispatched.promise,replies,request,status,owner,admin,member,disconnect,connect,connectedListeners,disconnectedListeners,reconnects:()=>reconnects};
}
const nonce=()=>({clientNonce:crypto.randomUUID()});
// Real subprocess integration: poll the public receipt, not an assumed launcher duration.
async function finished(f:{status():Promise<P.InstanceStatus>}){for(let i=0;i<200;i++){const value=await f.status();if(value.runtime.operation?.state!=='running')return value.runtime.operation!;await Bun.sleep(10);}throw new Error('Launcher did not finish.');}

describe('instance management',()=>{
  test('launcher deadline kills the process and records failure',async()=>{
    const dir=await mkdtemp(join(tmpdir(),'lemon-instance-deadline-'));
    try {
      const launcher=join(dir,'launcher');await Bun.write(launcher,'#!/bin/sh\nwhile :; do :; done\n');await chmod(launcher,0o700);
      const f=await fixture(launcher);vi.useFakeTimers();
      try{expect((await f.request('/v1/instance/runtime/start',nonce())).status).toBe(202);vi.advanceTimersByTime(300000);}finally{vi.useRealTimers();}
      const result=await finished(f);expect(result.state).toBe('failed');expect(result.completedAtMs).not.toBeNull();expect(f.reconnects()).toBe(0);
    }finally{await rm(dir,{recursive:true,force:true});}
  });
  test('connected status maps upstream fields and matches the committed client wire fixture',async()=>{
    const f=await fixture();const value=await f.status();
    const fixtureFile=new URL('../../../sdk/ts/test/fixtures/instance-status.json',import.meta.url);
    expect(value).toEqual(await Bun.file(fixtureFile).json());expect(f.calls.sort()).toEqual(['health','nodes.list','sessions.active.list','status']);
    expect((await f.request('/v1/instance',undefined,f.admin.token)).status).toBe(200);
  });
  test('disconnected and rejected links report explicit reasons without upstream requests',async()=>{
    const f=await fixture();f.services.lemon.connected=false;
    for(const state of ['reconnecting','rejected'] as const){f.services.lemon.controller.state=state;f.services.lemon.controller.lastError={code:'controller_rejected',message:'The controller rejected the operator token. Check LEMON_BOT_OPERATOR_TOKEN.',atMs:1791940000000};const value=await f.status();expect(value.controller.state).toBe(state);expect(value.lemon).toBeNull();expect(value.lemonUnavailableReason).toBe(f.services.lemon.controller.lastError.message);}
    expect(f.calls).toEqual([]);
    expect((await f.request('/v1/instance/reconnect',nonce(),f.admin.token)).status).toBe(200);expect(f.reconnects()).toBe(1);
  });
  test('missing methods and upstream failures remain null, with health fallback',async()=>{
    const f=await fixture();f.services.lemon.methods=['health'];const value=await f.status();expect(value.lemon).toMatchObject({version:null,uptimeMs:12001,memoryMb:257,connections:null,runs:null,nodes:null,activeSessions:null});expect(f.calls).toEqual(['health']);
    f.replies.health=new Error('private timeout');expect((await f.status()).lemon).toBeNull();
    f.services.lemon.methods=[];expect((await f.status()).lemonUnavailableReason).toBe('The controller did not provide instance status.');
  });
  test('unanswered reads are bounded in parallel and become null',async()=>{
    const f=await fixture();for(const method of f.services.lemon.methods)f.replies[method]=Promise.withResolvers<unknown>().promise;
    // Exercise the real API deadline; no network or default daemon is involved.
    const value=await f.status();expect(value.lemon).toBeNull();expect(value.lemonUnavailableReason).not.toBeNull();
  },7000);
  test('unconfigured or unsupported remote lifecycle is explicitly unavailable',async()=>{
    const f=await fixture();f.services.lemon.methods=f.services.lemon.methods.filter(method=>!method.startsWith('system.'));
    expect((await f.status()).runtime).toMatchObject({actions:[],via:null});const response=await f.request('/v1/instance/runtime/start',nonce());expect(response.status).toBe(503);expect((await response.json()).error.code).toBe('capability_unavailable');
    f.services.config.controlUrl='wss://controller.example/ws';const value=await f.status();expect(value.runtime.actions).toEqual([]);expect(value.runtime.reason).not.toBeNull();
  });
  test('launcher validates absolute executable paths',async()=>{
    await expect(validateRuntimeLauncher('relative')).rejects.toThrow('LEMON_BOT_RUNTIME_LAUNCHER');await expect(validateRuntimeLauncher('/does/not/exist')).rejects.toThrow('existing executable');
    const dir=await mkdtemp(join(tmpdir(),'lemon-instance-config-'));try{const path=join(dir,'launcher');await Bun.write(path,'not executable');await chmod(path,0o600);await expect(validateRuntimeLauncher(path)).rejects.toThrow('existing executable');await chmod(path,0o700);await validateRuntimeLauncher(path);}finally{await rm(dir,{recursive:true,force:true});}
  });
  test('lifecycle returns 202, enforces confirmation and concurrency, strips env and uses exact argv',async()=>{
    const dir=await mkdtemp(join(tmpdir(),'lemon-instance-launch-'));const launcher=join(dir,'launcher');const record=join(dir,'argv');
    const old=process.env.LEMON_BOT_OPERATOR_TOKEN;process.env.LEMON_BOT_OPERATOR_TOKEN='must-not-leak';process.env.LEMON_BOT_TEST_SECRET='also-private';
    try{await Bun.write(launcher,`#!/bin/sh\nprintf '%s\\n' "$0" "$#" "$@" > '${record}'\n/usr/bin/env >> '${record}'\nsleep 0.1\nprintf 'launcher finished'\n`);await chmod(launcher,0o700);const f=await fixture(launcher);
      expect((await f.status()).runtime).toMatchObject({actions:['start','stop','restart'],via:'launcher',reason:null});
      const unconfirmed=await f.request('/v1/instance/runtime/stop',nonce());expect((await unconfirmed.json()).error.code).toBe('confirmation_required');
      for(const action of ['start','stop','restart'] as const){const body={...nonce(),confirm:action!=='start'};const response=await f.request(`/v1/instance/runtime/${action}`,body);expect(response.status).toBe(202);const receipt=await response.json();expect(receipt.state).toBe('running');
        const replay=await f.request(`/v1/instance/runtime/${action}`,body);expect(await replay.json()).toEqual(receipt);
        const concurrent=await f.request('/v1/instance/runtime/start',nonce());expect((await concurrent.json()).error.code).toBe('conflict');
        const result=await finished(f);expect(result.state).toBe('succeeded');expect(result.exitCode).toBe(0);expect(result.output).toBe('launcher finished');expect(result.completedAtMs).not.toBeNull();
        const recordText=await Bun.file(record).text();expect(recordText.split('\n').slice(0,3)).toEqual([launcher,'1',action==='start'?'daemon':action]);expect(recordText).not.toContain('LEMON_BOT_');expect(recordText).not.toContain('must-not-leak');
      }expect(f.reconnects()).toBe(2);
    }finally{if(old===undefined)delete process.env.LEMON_BOT_OPERATOR_TOKEN;else process.env.LEMON_BOT_OPERATOR_TOKEN=old;delete process.env.LEMON_BOT_TEST_SECRET;await rm(dir,{recursive:true,force:true});}
  });
  test('launcher failures retain exit code and bounded output tail',async()=>{
    const dir=await mkdtemp(join(tmpdir(),'lemon-instance-fail-'));try{const launcher=join(dir,'launcher');await Bun.write(launcher,"#!/bin/sh\ni=0; while [ $i -lt 5000 ]; do printf x; i=$((i+1)); done\nprintf end >&2\nexit 9\n");await chmod(launcher,0o700);const f=await fixture(launcher);expect((await f.request('/v1/instance/runtime/start',nonce())).status).toBe(202);const result=await finished(f);expect(result.state).toBe('failed');expect(result.exitCode).toBe(9);expect(Buffer.byteLength(result.output)).toBeLessThanOrEqual(4096);expect(f.reconnects()).toBe(0);}finally{await rm(dir,{recursive:true,force:true});}
  });
  test('malformed optional health sections are independently null without losing valid status',async()=>{
    const f=await fixture();const upstream=f.replies.status as Record<string,any>;
    upstream.server.build={runtimeMode:7};upstream.providers=[{id:'openai',credential:'secret'}];upstream.channels.details=[{id:'telegram',state:'unknown'}];upstream.lifecycle={restart:'yes'};
    const value=await f.status();expect(value.lemon).toMatchObject({version:'2026.10.9',build:null,providers:null,channels:null,activeSessions:7});expect(value.runtime.actions).toEqual([]);
    delete upstream.server.build;delete upstream.providers;delete upstream.channels;delete upstream.lifecycle;
    expect((await f.status()).lemon).toMatchObject({build:null,providers:null,channels:null});
  });
  test('remote controller actions intersect advertised methods and lifecycle; launcher is loopback-only',async()=>{
    const f=await fixture('/unused/launcher','wss://controller.example/ws');expect((await f.status()).runtime).toMatchObject({actions:['restart','stop'],via:'controller'});
    const upstream=f.replies.status as Record<string,any>;upstream.lifecycle.restart=false;upstream.lifecycle.reason='Restart requires a launcher-managed Lemon runtime.';
    expect((await f.status()).runtime).toMatchObject({actions:['stop'],reason:upstream.lifecycle.reason});
    f.services.lemon.methods=f.services.lemon.methods.filter(method=>method!=='system.stop');expect((await f.status()).runtime.actions).toEqual([]);
    f.disconnect();expect((await f.status()).runtime).toMatchObject({actions:[],via:null});
    expect((await f.request('/v1/instance/runtime/start',nonce())).status).toBe(503);
  });
  test('disconnected loopback launcher retains all actions without status RPCs',async()=>{
    const f=await fixture('/unused/launcher');f.disconnect();
    expect((await f.status()).runtime).toMatchObject({actions:['start','stop','restart'],via:'launcher',reason:null});expect(f.calls).toEqual([]);
  });
  test('link events racing the accepted receipt still complete the operation',async()=>{
    for(const action of ['restart','stop'] as const) {
      const f=await fixture();const reply=Promise.withResolvers<unknown>();f.replies[`system.${action}`]=reply.promise;
      const pending=f.request(`/v1/instance/runtime/${action}`,{...nonce(),confirm:true});
      await f.dispatched;
      f.disconnect();if(action==='restart')f.connect();
      reply.resolve({accepted:true,action,acceptedAtMs:1791940000000});
      const response=await pending;expect(response.status).toBe(202);expect((await response.json()).state).toBe('succeeded');
      expect(f.connectedListeners.size).toBe(0);expect(f.disconnectedListeners.size).toBe(0);
    }
  });
  test('controller restart awaits a new connection timestamp and never replays its mutation',async()=>{
    const f=await fixture(undefined,'wss://controller.example/ws');
    expect((await f.request('/v1/instance/runtime/restart',nonce())).status).toBe(409);
    const body={...nonce(),confirm:true};const response=await f.request('/v1/instance/runtime/restart',body);expect(response.status).toBe(202);const receipt=await response.json();expect(receipt.state).toBe('running');expect(receipt.exitCode).toBeNull();
    expect((await f.request('/v1/instance/runtime/stop',{...nonce(),confirm:true})).status).toBe(409);
    expect(await (await f.request('/v1/instance/runtime/restart',body)).json()).toEqual(receipt);expect(f.mutations).toHaveLength(1);
    f.connect(1791940000000);expect((await f.status()).runtime.operation?.state).toBe('running');
    f.disconnect();expect((await f.status()).runtime.operation?.state).toBe('running');
    f.connect();const completed=(await f.status()).runtime.operation!;expect(completed.state).toBe('succeeded');expect(completed.completedAtMs).not.toBeNull();expect(completed.exitCode).toBeNull();expect(completed.output).toContain('reconnected');
    expect(f.connectedListeners.size).toBe(0);expect(f.disconnectedListeners.size).toBe(0);expect(f.reconnects()).toBe(0);
  });
  test('controller stop succeeds only after link disconnects',async()=>{
    const f=await fixture();const response=await f.request('/v1/instance/runtime/stop',{...nonce(),confirm:true});expect(response.status).toBe(202);expect((await response.json()).state).toBe('running');
    f.disconnect();const operation=(await f.status()).runtime.operation!;expect(operation.state).toBe('succeeded');expect(operation.exitCode).toBeNull();expect(operation.output).toContain('disconnected');
  });
  test('controller lifecycle times out after 300 seconds and removes observers',async()=>{
    const f=await fixture();vi.useFakeTimers();
    try{expect((await f.request('/v1/instance/runtime/restart',{...nonce(),confirm:true})).status).toBe(202);vi.advanceTimersByTime(300000);}finally{vi.useRealTimers();}
    expect((await f.status()).runtime.operation).toMatchObject({state:'failed',exitCode:null,output:'The controller did not complete the operation within 300 seconds.'});expect(f.connectedListeners.size).toBe(0);expect(f.disconnectedListeners.size).toBe(0);
  });
  test('controller rejection fails the receipt without waiting for a link change',async()=>{
    const f=await fixture();f.replies['system.restart']=new Error('private controller rejection');
    expect((await f.request('/v1/instance/runtime/restart',{...nonce(),confirm:true})).status).toBe(500);
    expect((await f.status()).runtime.operation).toMatchObject({state:'failed',exitCode:null,output:'The controller lifecycle request could not be confirmed.'});expect(f.connectedListeners.size).toBe(0);expect(f.disconnectedListeners.size).toBe(0);
  });
  test('members cannot inspect/reconnect and non-owners cannot run lifecycle actions',async()=>{
    const f=await fixture();for(const [path,body] of [['/v1/instance',undefined],['/v1/instance/reconnect',nonce()],['/v1/instance/runtime/start',nonce()]] as const){const response=await f.request(path,body,f.member.token);expect(response.status).toBe(403);expect((await response.json()).error.code).toBe('forbidden');}
    expect((await f.request('/v1/instance/runtime/start',nonce(),f.admin.token)).status).toBe(403);
  });
});
