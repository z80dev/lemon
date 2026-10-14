import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import type { BackendServices, Principal, RequestContext } from './services';
import type * as P from '../../../contracts/protocol';
import { fail } from './errors';
const cursorSchema=z.object({userId:z.string(),binding:z.string(),after:z.string(),expiresAtMs:z.number()}).strict();
const actorSchema=z.object({kind:z.enum(['user','bot','system']),id:z.string().nullable(),displayName:z.string().max(120)}).strict();
const targetId=z.string().min(1).max(128).regex(/^[^/\u0000-\u0020]+$/);
const targetSchema=z.discriminatedUnion('kind',[
  z.object({kind:z.literal('entry'),botId:targetId,conversationId:targetId,taskConversationId:targetId.nullable(),entryId:targetId}).strict(),
  z.object({kind:z.literal('approval'),botId:targetId,conversationId:targetId,approvalId:targetId,entryId:targetId}).strict(),
  z.object({kind:z.literal('machine'),machineId:targetId,botId:targetId.nullable()}).strict(),
  z.object({kind:z.literal('routine'),botId:targetId,routineId:targetId,routineRunId:targetId.nullable()}).strict()
]);
const notificationInput=z.object({userId:z.string().optional(),conversationId:z.string().nullable().optional(),botId:z.string().nullable().optional(),entryId:z.string().nullable().optional(),kind:z.enum(['result','approval','question','human_step','error','machine']),title:z.string().max(200),body:z.string().max(1024),requestId:z.string().nullable().optional(),target:z.unknown().optional(),deepLink:z.string().optional()}).strict();
export function installHelpers(services:BackendServices):void {
  services.id=(prefix='id')=>`${prefix}_${randomBytes(18).toString('base64url')}`;
  services.now=()=>Date.now();
  services.resource=(prefix,fields)=>{const time=services.now();return {...fields,id:services.id(prefix),revision:1,createdAtMs:time,updatedAtMs:time};};
  services.update=(resource,changes)=>({...resource,...changes,revision:resource.revision+1,updatedAtMs:services.now()});
  services.page=<T>(context:RequestContext,values:T[],options?:{ascending?:boolean;key?:(value:T)=>string;binding?:unknown}):P.Page<T>=>{
    const limit=z.coerce.number().int().min(1).max(200).parse(context.query.get('limit')??50);
    const filters=[...context.query.entries()].filter(([key])=>key!=='cursor').sort(([a],[b])=>a.localeCompare(b));
    const binding=services.mutations.digest({path:context.route.path,params:context.params,filters,ascending:options?.ascending??false,extra:options?.binding??null});
    const userId=context.user?.userId??'public';const encoded=context.query.get('cursor');let after:string|null=null;
    if(encoded) {
      if(!/^\d{1,12000}$/.test(encoded))fail('invalid_request','Page cursor is invalid.');
      try {let hex=BigInt(encoded).toString(16);if(hex.length%2)hex='0'+hex;const cursor=cursorSchema.parse(services.decrypt(Buffer.from(hex,'hex').toString('base64url')));if(cursor.userId!==userId||cursor.binding!==binding)fail('invalid_request','Cursor belongs to different filters or principal.');if(cursor.expiresAtMs<=services.now())fail('expired','Page cursor expired.');after=cursor.after;}catch(error){if(error instanceof Error&&error.name==='ApiError')throw error;fail('invalid_request','Page cursor is invalid.');}
    }
    const key=options?.key??((value:T)=>{const shape=z.object({id:z.string(),createdAtMs:z.number().optional()}).passthrough().parse(value);return `${String(shape.createdAtMs??0).padStart(16,'0')}:${shape.id}`;});
    const ascending=options?.ascending??false;
    const sorted=[...values].sort((a,b)=>ascending?key(a).localeCompare(key(b)):key(b).localeCompare(key(a)));
    const remaining=after===null?sorted:sorted.filter(value=>ascending?key(value)>after!:key(value)<after!);
    const items=remaining.slice(0,limit);let nextCursor:string|null=null;
    if(remaining.length>limit&&items.length) {const payload=services.encrypt({userId,binding,after:key(items[items.length-1]!),expiresAtMs:services.now()+86400000});nextCursor=BigInt('0x'+Buffer.from(payload,'base64url').toString('hex')).toString();}
    return {items,nextCursor};
  };
  services.audit=(principal,action,targetId,outcome,details={},requestId=services.id('req'))=>{
    const safe:P.JSONObject={};
    for(const [key,value] of Object.entries(details)) {if(/secret|token|password|prompt|body|text|path|url|email/i.test(key))continue;if(typeof value==='boolean'||typeof value==='number'&&Number.isFinite(value)||value===null)safe[key]=value;else if(typeof value==='string'&&/^[A-Za-z0-9_.:-]{0,128}$/.test(value))safe[key]=value;}
    const actor:P.Actor=principal?{kind:principal.kind==='bot'?'bot':'user',id:principal.kind==='bot'?principal.botId:principal.userId,displayName:principal.kind==='bot'?'Bot':services.store.get<P.User>('users',principal.userId)?.displayName??'Member'}:{kind:'system',id:null,displayName:'System'};
    const record=services.resource('audit',{actor,action:action.slice(0,128),resourceType:action.split('.')[0]??'resource',resourceId:targetId,outcome,requestId,metadata:safe});
    return services.store.put('auditRecords',record);
  };
  services.entry=(principal,conversationId,payload)=>services.store.transaction(()=>{
    const conversation=services.auth.conversation(principal,conversationId);
    const seq=services.store.list<P.TranscriptEntry>('entries',entry=>entry.conversationId===conversationId).reduce((max,entry)=>Math.max(max,entry.seq),0)+1;
    const envelope=services.resource('entry',{conversationId,seq,timestampMs:services.now(),actor:payload.actor?actorSchema.parse(payload.actor):{kind:principal.kind==='bot'?'bot':'user',id:principal.kind==='bot'?principal.botId:principal.userId,displayName:principal.kind==='bot'?'Bot':services.auth.user(principal.userId).displayName},clientNonce:typeof payload.clientNonce==='string'?payload.clientNonce:null,batchId:typeof payload.batchId==='string'?payload.batchId:null,replyToEntryId:typeof payload.replyToEntryId==='string'?payload.replyToEntryId:null,runId:typeof payload.runId==='string'?payload.runId:null,targetedUserId:typeof payload.targetedUserId==='string'?payload.targetedUserId:null,reactions:[]});
    if(typeof payload.id==='string')envelope.id=payload.id;
    const kind=z.enum(['message','card','user_attachment','tool_call','mcp_app','notice','event','feedback','voice_call']).parse(payload.kind);
    const keys:Record<typeof kind,string[]>={message:['role','text','streaming','attachmentIds'],card:['card'],user_attachment:['attachmentId'],tool_call:['tool','title','status','detail'],mcp_app:['connectorId','resourceUri','snapshotAttachmentId','state'],notice:['severity','text','requestId'],event:['event'],feedback:['feedback'],voice_call:['voiceSession']};
    const fields:Record<string,unknown>={};for(const name of keys[kind]) {if(!(name in payload))fail('internal_error','Transcript payload is incomplete.',false);fields[name]=payload[name];}
    // Callers construct exhaustive contract payloads; this helper validates and owns the common envelope and strips extra internal metadata.
    const entry={...envelope,kind,...fields} as unknown as P.TranscriptEntry;
    services.store.put('entries',entry);const updated=services.update(conversation,{lastEntryId:entry.id});services.store.put('conversations',updated);
    services.events.emit('entry.upserted',entry,{conversationId,userIds:entry.targetedUserId?[entry.targetedUserId]:undefined});services.events.emit('conversation.upserted',updated,{conversationId});
    return entry;
  });
  services.notify=(principal:Principal,input)=>services.store.transaction(()=>{
    const parsed=notificationInput.parse(input);const userId=parsed.userId??principal.userId;services.auth.user(userId);
    let conversationId=parsed.conversationId??null;let botId=parsed.botId??null;let entryId=parsed.entryId??null;const workspaceId=principal.workspaceId;
    let target:P.NotificationTarget;let deepLink:string;
    if(parsed.target){
      target=targetSchema.parse(parsed.target);
      botId=target.botId;
      if(target.kind==='entry'||target.kind==='approval'){conversationId=target.conversationId;entryId=target.entryId;}
      if(target.kind==='machine'){deepLink=`lemonbot://workspace/${encodeURIComponent(workspaceId)}/machine/${encodeURIComponent(target.machineId)}`+(botId?`?botId=${encodeURIComponent(botId)}`:'');}
      else if(target.kind==='routine'){deepLink=`lemonbot://workspace/${encodeURIComponent(workspaceId)}/bot/${encodeURIComponent(target.botId)}/routine/${encodeURIComponent(target.routineId)}`+(target.routineRunId?`?routineRunId=${encodeURIComponent(target.routineRunId)}`:'');}
      else {const params=new URLSearchParams({conversationId:target.conversationId,entryId:target.entryId});if(target.kind==='approval')params.set('approvalId',target.approvalId);else if(target.taskConversationId)params.set('taskConversationId',target.taskConversationId);deepLink=`lemonbot://workspace/${encodeURIComponent(workspaceId)}/bot/${encodeURIComponent(target.botId)}?${params}`;}
    }else {if(!botId||!conversationId||!entryId)fail('internal_error','Notification navigation target is required.',false);target={kind:'entry',botId,conversationId,taskConversationId:services.store.get<P.Conversation>('conversations',conversationId)?.kind==='task'?conversationId:null,entryId};const params=new URLSearchParams({conversationId,entryId});if(target.taskConversationId)params.set('taskConversationId',target.taskConversationId);deepLink=`lemonbot://workspace/${encodeURIComponent(workspaceId)}/bot/${encodeURIComponent(botId)}?${params}`;}
    const notification=services.resource('notification',{userId,conversationId,botId,entryId,kind:parsed.kind,title:parsed.title,body:parsed.body,requestId:parsed.requestId??null,readAtMs:null,dismissedAtMs:null,target,deepLink});
    services.store.put('notifications',notification);services.events.emit('notification.upserted',notification,{userIds:[userId]});
    void services.integrations.emitProviderNotifications(notification).catch(()=>{services.audit(null,'notification.delivery',notification.id,'failed');});
    return notification;
  });
}
