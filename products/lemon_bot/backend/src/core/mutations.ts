import { createHmac, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type { BackendServices, MutationService, Principal, RequestContext } from './services';
import type { Confirmation, ScopeEffect } from '../../../contracts/protocol';
import { ApiError, fail } from './errors';
import { nonce, parse } from './validation';
function canonical(value:unknown):string {
  if(value===undefined) return 'null';
  if(Array.isArray(value)) return '['+value.map(canonical).join(',')+']';
  if(value!==null && typeof value==='object') return '{'+Object.entries(value).sort(([a],[b])=>a.localeCompare(b)).map(([key,item])=>JSON.stringify(key)+':'+canonical(item)).join(',')+'}';
  return JSON.stringify(value);
}
const confirmationBody=z.object({confirmationToken:z.string().min(16).max(512),confirmName:z.string(),revision:z.number().int().positive().optional()}).passthrough();
interface Reservation { hash:string;state:string;receipt:string|null;resource_ids:string }
interface ConfirmationRow {user_id:string;target_id:string;revision:number;action:string;name:string;binding:string;expires_at_ms:number;consumed:number}
export function createMutationService(services:BackendServices,key:Uint8Array):MutationService {
  const pending=new Map<string,Promise<unknown>>();
  const digest=(value:unknown)=>createHmac('sha256',key).update(canonical(value)).digest('hex');
  const db=services.store.db;
  return {
    digest,
    checkRevision(resource,revision) { if(!Number.isSafeInteger(revision)||resource.revision!==revision) fail('revision_conflict','Resource changed; reload before editing.',true,{currentRevision:resource.revision}); },
    async execute<T>(context:RequestContext,operation:()=>Promise<T>|T):Promise<T> {
      let input=context.body;
      if(input instanceof FormData) {
        const raw=input.get('metadata'); if(typeof raw!=='string') fail('invalid_request','Upload metadata is required.');
        const metadata:unknown=JSON.parse(raw); const files:Record<string,unknown>[]=[];
        for(const [name,value] of input) if(value instanceof File) files.push({name,filename:value.name,type:value.type,size:value.size,checksum:digest(Buffer.from(await value.arrayBuffer()).toString('base64'))});
        input={metadata,files};
      }
      const clientNonce=parse(nonce,z.object({clientNonce:z.unknown()}).passthrough().parse(input instanceof Object && 'metadata' in input ? input.metadata : input).clientNonce);
      const anonymous=z.object({email:z.string().optional()}).passthrough().safeParse(context.body);
      const actor=context.user ? `${context.user.workspaceId}:${context.user.kind}:${context.user.id}` : `anonymous:${anonymous.success ? anonymous.data.email?.trim().toLowerCase() ?? 'setup' : 'setup'}`;
      const scope=`${actor}:${context.route.method}:${new URL(context.request.url).pathname}`;
      const identity=`${scope}:${clientNonce}`; const hash=digest(input);
      const existing=db.query('SELECT hash,state,receipt,resource_ids FROM nonces WHERE scope=? AND nonce=?').get(scope,clientNonce) as Reservation|null;
      if(existing) {
        if(existing.hash!==hash) fail('nonce_conflict','This client nonce was already used for a different request.');
        const running=pending.get(identity); if(running) return await running as T;
        if(existing.receipt) {
          const receipt=services.decrypt<{ok:boolean;value?:T;error?:{code:ApiError['code'];message:string;retrySafe:boolean;details?:ApiError['details']}}>(existing.receipt);
          if(!receipt.ok && receipt.error) throw new ApiError(receipt.error.code,receipt.error.message,receipt.error.retrySafe,receipt.error.details);
          return receipt.value as T;
        }
        fail('outcome_unknown','The original mutation may have taken effect; reconcile its resources before taking another action.',false,{resourceIds:z.array(z.string()).parse(JSON.parse(existing.resource_ids))});
      }
      db.query('INSERT INTO nonces(scope,nonce,hash,state,created_at_ms) VALUES(?,?,?,\'reserved\',?)').run(scope,clientNonce,hash,services.now());
      context.nonceResourceIds=new Proxy(context.nonceResourceIds,{set(target,property,value){Reflect.set(target,property,value);db.query('UPDATE nonces SET resource_ids=? WHERE scope=? AND nonce=?').run(JSON.stringify(target),scope,clientNonce);return true;}});
      const promise=(async()=>{
        try { const value=await operation(); if(value instanceof Response) fail('internal_error','Mutation handlers must return a typed resource receipt.',false); db.query('UPDATE nonces SET state=\'complete\',receipt=?,resource_ids=? WHERE scope=? AND nonce=?').run(services.encrypt({ok:true,value}),JSON.stringify(context.nonceResourceIds),scope,clientNonce); return value; }
        catch(error) { const known=error instanceof ApiError?error:new ApiError('internal_error','The mutation could not be confirmed.',false); db.query('UPDATE nonces SET state=?,receipt=?,resource_ids=? WHERE scope=? AND nonce=?').run(known.code==='outcome_unknown'?'unknown':'failed',services.encrypt({ok:false,error:{code:known.code,message:known.message,retrySafe:known.retrySafe,details:known.details}}),JSON.stringify(context.nonceResourceIds),scope,clientNonce); throw known; }
        finally { pending.delete(identity); }
      })();
      pending.set(identity,promise);
      return await promise;
    },
    preview(principal:Principal,target,action,name,effects:string[],affected:ScopeEffect[]=[],binding:unknown=null,expiresInMs=300000):Confirmation {
      const ttl=z.number().int().min(1000).max(action==='memory_import'?600000:300000).parse(expiresInMs);
      const token=services.id('confirm'); const expiresAtMs=services.now()+ttl;
      db.query('INSERT INTO confirmations(token_digest,user_id,target_id,revision,action,name,binding,expires_at_ms) VALUES(?,?,?,?,?,?,?,?)').run(digest(token),principal.userId,target.id,target.revision,action,name,digest(binding),expiresAtMs);
      return {confirmationToken:token,revision:target.revision,confirmName:name,expiresAtMs,effects,affected};
    },
    confirm(principal,target,action,body,binding:unknown=null) {
      const input=parse(confirmationBody,body); const row=db.query('SELECT * FROM confirmations WHERE token_digest=?').get(digest(input.confirmationToken)) as ConfirmationRow|null;
      if(!row||row.user_id!==principal.userId||row.target_id!==target.id||row.action!==action) fail('confirmation_required','Preview this exact operation before confirming.');
      if(row.consumed||row.expires_at_ms<=services.now()) fail('expired','The confirmation expired or was already consumed.');
      if(row.revision!==target.revision||input.revision!==undefined&&input.revision!==target.revision) fail('revision_conflict','Resource changed; repeat the preview.',true,{currentRevision:target.revision});
      const expected=Buffer.from(row.binding);const actual=Buffer.from(digest(binding));
      if(!timingSafeEqual(expected,actual)||input.confirmName!==row.name) fail('confirmation_required','Confirmation does not match the exact previewed scope.');
      const receipt=db.query('UPDATE confirmations SET consumed=1 WHERE token_digest=? AND consumed=0').run(digest(input.confirmationToken));
      if(receipt.changes!==1) fail('conflict','The confirmation was already used.');
    }
  };
}
