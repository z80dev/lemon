import { describe, expect, test, vi } from 'bun:test';
import { mkdtemp, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import { authFixture } from './auth.test';
import { createInstanceRoutes } from '../../src/core/instance';
import { Router } from '../../src/core/router';
import { validateRuntimeLauncher } from '../../src/core/config';

async function fixture(launcher?:string) {
  const f=authFixture();f.services.config.runtimeLauncher=launcher;
  const calls:string[]=[];let reconnects=0;
  const replies:Record<string,unknown>={status:{server:{version:'0.1.0',uptime_ms:12000,memory_mb:256.5},connections:{active:3,operators:1,nodes:2},runs:{active:1,queued:2,completed_today:4},channels:{configured:['telegram'],connected:['telegram']},skills:{installed:10,enabled:8}},health:{uptime_ms:12001,memory_mb:257},'sessions.active.list':{summary:{count:7}},'nodes.list':{summary:{count:3,online:2,presenceAvailable:true,truncated:false}}};
  f.services.lemon={connected:true,methods:Object.keys(replies),controller:{url:f.services.config.controlUrl,state:'connected',connectedAtMs:1791940000000,lastDisconnectedAtMs:null,lastError:null,nextRetryAtMs:null,methodCount:4},async call<T>(method:string,_params?:Record<string,unknown>,options?:{timeoutMs?:number}){calls.push(method);expect(options?.timeoutMs).toBe(5000);const reply=replies[method];if(reply instanceof Error)throw reply;return await reply as T;},reconnect(){reconnects++;},onConnected:()=>()=>{},onEvent:()=>()=>{},start(){},close(){}};
  const router=new Router(f.services);router.register(createInstanceRoutes(f.services,1791939999000));
  const owner=await f.services.auth.session('owner'),admin=await f.services.auth.session('admin'),member=await f.services.auth.session('alice');
  async function request(path='/v1/instance',body?:unknown,token=owner.token){return router.fetch(new Request(`https://lemon.example${path}`,{method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})}));}
  async function status(){const response=await request();expect(response.status).toBe(200);return await response.json() as P.InstanceStatus;}
  return {...f,calls,replies,request,status,owner,admin,member,reconnects:()=>reconnects};
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
  test('unconfigured or remote lifecycle is explicitly unavailable',async()=>{
    const f=await fixture();expect((await f.status()).runtime.controllable).toBe(false);const response=await f.request('/v1/instance/runtime/start',nonce());expect(response.status).toBe(503);expect((await response.json()).error.code).toBe('capability_unavailable');
    f.services.config.controlUrl='wss://controller.example/ws';const router=new Router(f.services);router.register(createInstanceRoutes(f.services,0));const response2=await router.fetch(new Request('https://lemon.example/v1/instance',{headers:{Authorization:`Bearer ${f.owner.token}`}}));expect((await response2.json()).runtime.reason).toBe('The controller is not on this host; restart it where it runs.');
  });
  test('launcher validates absolute executable paths',async()=>{
    await expect(validateRuntimeLauncher('relative')).rejects.toThrow('LEMON_BOT_RUNTIME_LAUNCHER');await expect(validateRuntimeLauncher('/does/not/exist')).rejects.toThrow('existing executable');
    const dir=await mkdtemp(join(tmpdir(),'lemon-instance-config-'));try{const path=join(dir,'launcher');await Bun.write(path,'not executable');await chmod(path,0o600);await expect(validateRuntimeLauncher(path)).rejects.toThrow('existing executable');await chmod(path,0o700);await validateRuntimeLauncher(path);}finally{await rm(dir,{recursive:true,force:true});}
  });
  test('lifecycle returns 202, enforces confirmation and concurrency, strips env and uses exact argv',async()=>{
    const dir=await mkdtemp(join(tmpdir(),'lemon-instance-launch-'));const launcher=join(dir,'launcher');const record=join(dir,'argv');
    const old=process.env.LEMON_BOT_OPERATOR_TOKEN;process.env.LEMON_BOT_OPERATOR_TOKEN='must-not-leak';process.env.LEMON_BOT_TEST_SECRET='also-private';
    try{await Bun.write(launcher,`#!/bin/sh\nprintf '%s\\n' "$0" "$#" "$@" > '${record}'\n/usr/bin/env >> '${record}'\nsleep 0.1\nprintf 'launcher finished'\n`);await chmod(launcher,0o700);const f=await fixture(launcher);
      expect((await f.status()).runtime.controllable).toBe(true);
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
  test('members cannot inspect/reconnect and non-owners cannot run lifecycle actions',async()=>{
    const f=await fixture();for(const [path,body] of [['/v1/instance',undefined],['/v1/instance/reconnect',nonce()],['/v1/instance/runtime/start',nonce()]] as const){const response=await f.request(path,body,f.member.token);expect(response.status).toBe(403);expect((await response.json()).error.code).toBe('forbidden');}
    expect((await f.request('/v1/instance/runtime/start',nonce(),f.admin.token)).status).toBe(403);
  });
});
