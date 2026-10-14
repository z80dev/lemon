import { describe, expect, test } from 'bun:test';
import { randomBytes } from 'node:crypto';
import { Store } from '../../src/core/store';
import { createMutationService } from '../../src/core/mutations';
import { createPrivateCodec } from '../../src/core/config';
import { installHelpers } from '../../src/core/helpers';
import { ApiError } from '../../src/core/errors';
import type { BackendServices, Principal, RequestContext } from '../../src/core/services';
const user:Principal={kind:'user',id:'user_one',userId:'user_one',workspaceId:'workspace_one',role:'owner',sessionId:'session_one',botId:null,deviceId:null};
function fixture(){
  const store=new Store(':memory:');const key=randomBytes(32);
  // Only mutation/pagination boundaries are exercised; uninstalled unrelated services are never called.
  const services={store,...createPrivateCodec(key)} as unknown as BackendServices;
  installHelpers(services);services.mutations=createMutationService(services,key);
  const context=(body:unknown):RequestContext=>({request:new Request('http://127.0.0.1:4080/v1/bots',{method:'POST'}),params:{},query:new URLSearchParams(),body,user,services,requestId:'request_one',route:{method:'POST',path:'/v1/bots',auth:'member',handler:()=>{throw new Error('unused handler');}},nonceResourceIds:[]});
  return {services,store,key,context};
}
describe('durable product mutation boundaries',()=>{
  test('concurrent same intent dispatches once and replays the exact receipt',async()=>{
    const {services,store,context}=fixture();let dispatched=0;const completion=Promise.withResolvers<{id:string}>();
    const operation=()=>{dispatched++;return completion.promise;};
    const body={clientNonce:'same_intent_nonce_001',name:'Finance'};
    const first=services.mutations.execute(context(body),operation);const second=services.mutations.execute(context(body),operation);
    await Promise.resolve();completion.resolve({id:'fixed_bot'});
    expect(await first).toEqual({id:'fixed_bot'});expect(await second).toEqual({id:'fixed_bot'});expect(dispatched).toBe(1);
    expect(await services.mutations.execute(context(body),operation)).toEqual({id:'fixed_bot'});expect(dispatched).toBe(1);store.close();
  });
  test('nonce cannot be reused for another body or expose submitted secrets in journal',async()=>{
    const {services,store,context}=fixture();const secret='private-credential-never-journalled';
    await services.mutations.execute(context({clientNonce:'secret_intent_nonce_001',value:secret}),()=>({ok:true}));
    await expect(services.mutations.execute(context({clientNonce:'secret_intent_nonce_001',value:'changed'}),()=>({ok:true}))).rejects.toMatchObject({code:'nonce_conflict'});
    const row=store.db.query('SELECT * FROM nonces').get();expect(JSON.stringify(row)).not.toContain(secret);store.close();
  });
  test('restart fences a dispatched reservation and retains the fixed resource ids',async()=>{
    const {services,store,key,context}=fixture();const body={clientNonce:'unknown_intent_nonce_001'};const call=context(body);
    const completion=Promise.withResolvers<unknown>();
    const work=services.mutations.execute(call,()=>{call.nonceResourceIds.push('run_fixed');return completion.promise;});
    await Promise.resolve();
    const restarted=createMutationService(services,key);
    await expect(restarted.execute(context(body),()=>{throw new Error('must not redispatch');})).rejects.toMatchObject({code:'outcome_unknown',retrySafe:false,details:{resourceIds:['run_fixed']}});
    completion.reject(new ApiError('outcome_unknown','Dispatch acknowledgment was lost.',false,{runId:'run_fixed'}));await expect(work).rejects.toMatchObject({code:'outcome_unknown'});store.close();
  });
  test('confirmation binds target revision, scope, principal and is single use',()=>{
    const {services,store}=fixture();const target={id:'bot_fixed',revision:3};const binding={destination:'machine_two',memoryIds:['memory_one']};
    const preview=services.mutations.preview(user,target,'move','Finance',['Move persona'],[],binding);
    expect(()=>services.mutations.confirm({...user,userId:'another_user'},target,'move',{...preview},binding)).toThrow();
    expect(()=>services.mutations.confirm(user,{...target,revision:4},'move',{...preview},binding)).toThrow();
    expect(()=>services.mutations.confirm(user,target,'move',{...preview},{...binding,destination:'machine_three'})).toThrow();
    services.mutations.confirm(user,target,'move',{...preview},binding);
    expect(()=>services.mutations.confirm(user,target,'move',{...preview},binding)).toThrow();store.close();
  });
  test('page cursor is filter and principal bound, keyset based and tamper rejecting',()=>{
    const {services,store,context}=fixture();const call=context(undefined);call.query=new URLSearchParams({limit:'1',visibility:'personal'});
    const values=[{id:'a',createdAtMs:1},{id:'b',createdAtMs:2},{id:'c',createdAtMs:3}];const first=services.page(call,values);expect(first.items.map(value=>value.id)).toEqual(['c']);expect(first.nextCursor).toMatch(/^\d+$/);
    call.query.set('cursor',first.nextCursor!);expect(services.page(call,values).items.map(value=>value.id)).toEqual(['b']);
    call.query.set('visibility','team');expect(()=>services.page(call,values)).toThrow();call.query.set('visibility','personal');call.user={...user,userId:'other'};expect(()=>services.page(call,values)).toThrow();call.user=user;call.query.set('cursor',(BigInt(first.nextCursor!)+1n).toString());expect(()=>services.page(call,values)).toThrow();store.close();
  });
});
