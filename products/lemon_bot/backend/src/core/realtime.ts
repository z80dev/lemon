import type { ServerWebSocket } from 'bun';
import { z } from 'zod';
import type { BackendServices, EventAudience, Principal } from './services';
import type * as P from '../../../contracts/protocol';
import { ApiError, errorEnvelope, fail } from './errors';
const wireId=z.string().min(1).max(128).regex(/^[^/\u0000-\u0020]+$/);
const cursor=z.string().max(32).regex(/^\d+$/);
const frameSchema=z.discriminatedUnion('type',[
  z.object({type:z.literal('auth'),token:z.string().min(16).max(512),deviceId:wireId.optional()}).strict(),
  z.object({type:z.literal('subscribe'),requestId:wireId,cursor:cursor.optional(),conversationIds:z.array(wireId).max(200).optional()}).strict(),
  z.object({type:z.literal('ack'),cursor}).strict(),z.object({type:z.literal('ping'),requestId:wireId}).strict(),
  z.object({type:z.literal('typing'),conversationId:wireId,active:z.boolean()}).strict(),
  z.object({type:z.literal('presence'),foreground:z.boolean(),conversationId:wireId.nullable()}).strict(),
  z.object({type:z.literal('terminal_subscribe'),terminalId:wireId,afterSeq:z.number().int().nonnegative().optional()}).strict(),
  z.object({type:z.literal('voice'),voiceSessionId:wireId,action:z.enum(['mute','unmute','end'])}).strict()
]);
export interface RealtimeData {principal:Principal|null;token:string|null;deviceId:string|null;authenticated:boolean;subscribed:boolean;conversationIds:string[];delivered:string;acked:string;lastActivity:number;lastTyping:number;openedAt:number;queue:Promise<void>;terminalSubscriptions:Map<string,()=>void>}
export interface RealtimeHooks {
  terminalSubscribe?(principal:Principal,deviceId:string,terminalId:string,afterSeq:number|undefined,send:(frame:P.RealtimeServerFrame)=>void):()=>void;
  terminalDisconnect?(principal:Principal,deviceId:string):void;
  terminalConnect?(principal:Principal,deviceId:string):void;
  voiceConnect?(userId:string,deviceId:string):void;
  voiceDisconnect?(userId:string,deviceId:string):void;
}
export function createRealtime(services:BackendServices,hooks:RealtimeHooks={}) {
  const sockets=new Set<ServerWebSocket<RealtimeData>>();
  const send=(socket:ServerWebSocket<RealtimeData>,frame:P.RealtimeServerFrame)=>{if(socket.readyState===1)socket.send(JSON.stringify(frame));};
  const selected=(socket:ServerWebSocket<RealtimeData>,event:P.RealtimeEvent,audience:EventAudience)=>{
    if(!socket.data.conversationIds.length)return true;
    const conversationId=audience.conversationId??(typeof event.payload==='object'&&event.payload!==null&&'conversationId' in event.payload&&typeof event.payload.conversationId==='string'?event.payload.conversationId:undefined);
    return !conversationId||socket.data.conversationIds.includes(conversationId);
  };
  const project=(principal:Principal,event:P.RealtimeEvent):P.RealtimeEvent=>{
    if(event.event==='bot.upserted')return {...event,payload:services.auth.bot(principal,event.payload.id)};
    if(event.event==='conversation.upserted')return {...event,payload:services.auth.conversation(principal,event.payload.id)};
    return event;
  };
  const unsubscribe=services.events.subscribe((event,audience)=>{
    for(const socket of sockets){const principal=socket.data.principal;if(!principal||!socket.data.subscribed||!selected(socket,event,audience)||!services.events.visible(principal,event,audience))continue;try{send(socket,project(principal,event));socket.data.delivered=event.seq;}catch{/* A concurrently revoked resource is never disclosed. */}}
  });
  const heartbeat=setInterval(()=>{
    const now=services.now();for(const socket of sockets){if(!socket.data.authenticated&&now-socket.data.openedAt>=5000){socket.close(4408,'Authentication timed out.');continue;}if(now-socket.data.lastActivity>=60000){socket.close(4408,'Connection expired.');continue;}
      if(socket.data.principal){void services.auth.authenticate(new Request(services.config.publicUrl+'/v1/realtime',{headers:{Authorization:'Bearer '+socket.data.token}}),'member').then(user=>{if(!user){socket.close(4401,'Session expired or revoked.');return;}socket.data.principal={...user,deviceId:socket.data.deviceId};}).catch(()=>socket.close(4401,'Session expired or revoked.'));if(socket.data.subscribed){const watermark=services.events.cursor();send(socket,{type:'watermark',cursor:watermark});socket.data.delivered=watermark;}}
      socket.ping();
    }
  },25000);
  const processFrame=async(socket:ServerWebSocket<RealtimeData>,raw:string)=>{
    const parsed=frameSchema.safeParse(JSON.parse(raw));if(!parsed.success){socket.close(4400,'Invalid realtime frame.');return;}
    const frame=parsed.data;socket.data.lastActivity=services.now();
    if(!socket.data.authenticated){
      if(frame.type!=='auth'){socket.close(4401,'Authenticate first.');return;}
      const user=await services.auth.authenticate(new Request(services.config.publicUrl+'/v1/realtime',{headers:{Authorization:'Bearer '+frame.token}}),'member');if(!user){socket.close(4401,'Authentication failed.');return;}
      if(frame.deviceId){const device=services.store.require<P.Device>('devices',frame.deviceId);if(device.userId!==user.userId)fail('forbidden','Device belongs to another account.');}
      socket.data.principal={...user,deviceId:frame.deviceId??null};socket.data.deviceId=frame.deviceId??null;socket.data.token=frame.token;socket.data.authenticated=true;
      if(frame.deviceId){hooks.terminalConnect?.(user,frame.deviceId);hooks.voiceConnect?.(user.userId,frame.deviceId);}
      const watermark=services.events.cursor();socket.data.delivered=watermark;send(socket,{type:'ready',userId:user.userId,workspaceId:user.workspaceId,cursor:watermark,earliestCursor:services.events.earliestCursor(),heartbeatMs:25000});return;
    }
    if(frame.type==='auth'){socket.close(4400,'Authentication cannot be repeated.');return;}
    const refreshed=await services.auth.authenticate(new Request(services.config.publicUrl+'/v1/realtime',{headers:{Authorization:'Bearer '+socket.data.token}}),'member');
    if(!refreshed)fail('unauthenticated','Session expired or revoked.');
    const user={...refreshed,deviceId:socket.data.deviceId};socket.data.principal=user;
    if(frame.type==='subscribe'){
      const selection=[...new Set(frame.conversationIds??[])];for(const id of selection)services.auth.conversation(user,id);
      const watermark=services.events.cursor();const start=frame.cursor??watermark;
      const events=services.events.replay(user,start,selection);
      socket.data.conversationIds=selection;socket.data.subscribed=true;socket.data.delivered=start;
      send(socket,{type:'subscribed',requestId:frame.requestId,cursor:start,conversationIds:selection});for(const event of events){send(socket,project(user,event));socket.data.delivered=event.seq;}send(socket,{type:'caught_up',cursor:watermark});socket.data.delivered=watermark;return;
    }
    if(frame.type==='ack'){if(BigInt(frame.cursor)>BigInt(socket.data.delivered)||BigInt(frame.cursor)<BigInt(socket.data.acked))fail('invalid_request','Acknowledgement cursor was not delivered.');socket.data.acked=frame.cursor;return;}
    if(frame.type==='ping'){send(socket,{type:'pong',requestId:frame.requestId});return;}
    if(frame.type==='presence'){if(!socket.data.deviceId)fail('forbidden','An owned device is required for foreground presence.');if(frame.conversationId)services.auth.conversation(user,frame.conversationId);services.store.setMetadata('presence:'+socket.data.deviceId,{userId:user.userId,foreground:frame.foreground,conversationId:frame.conversationId,updatedAtMs:services.now()});return;}
    if(frame.type==='typing'){
      services.auth.conversation(user,frame.conversationId);if(!socket.data.subscribed||socket.data.conversationIds.length&&!socket.data.conversationIds.includes(frame.conversationId))fail('forbidden','Typing requires a subscribed conversation.');if(services.now()-socket.data.lastTyping<1000)return;socket.data.lastTyping=services.now();
      for(const recipient of sockets){const target=recipient.data.principal;if(!target||!recipient.data.subscribed)continue;try{services.auth.conversation(target,frame.conversationId);if(!recipient.data.conversationIds.length||recipient.data.conversationIds.includes(frame.conversationId))send(recipient,{type:'typing',conversationId:frame.conversationId,userId:user.userId,active:frame.active,expiresAtMs:services.now()+5000});}catch{/* Private room typing remains private. */}}return;
    }
    if(frame.type==='terminal_subscribe'){
      if(!socket.data.deviceId)fail('forbidden','An owned device is required for terminal access.');if(!hooks.terminalSubscribe)fail('capability_unavailable','The terminal runtime is not installed.');socket.data.terminalSubscriptions.get(frame.terminalId)?.();const remove=hooks.terminalSubscribe(user,socket.data.deviceId,frame.terminalId,frame.afterSeq,value=>send(socket,value));socket.data.terminalSubscriptions.set(frame.terminalId,remove);return;
    }
    const voice=services.store.require<P.VoiceSession>('voiceSessions',frame.voiceSessionId);if(voice.userId!==user.userId)fail('not_found','Voice session was not found.');
    if(frame.action==='end')await services.invoke(user,'POST',`/v1/voice/sessions/${encodeURIComponent(voice.id)}/end`,{clientNonce:services.id('voice_ws')});
    else if(voice.muted!==(frame.action==='mute'))await services.invoke(user,'PATCH',`/v1/voice/sessions/${encodeURIComponent(voice.id)}`,{clientNonce:services.id('voice_ws'),revision:voice.revision,muted:frame.action==='mute'});
  };
  return {
    data():RealtimeData {return {principal:null,token:null,deviceId:null,authenticated:false,subscribed:false,conversationIds:[],delivered:'0',acked:'0',lastActivity:services.now(),lastTyping:0,openedAt:services.now(),queue:Promise.resolve(),terminalSubscriptions:new Map()};},
    websocket:{
      maxPayloadLength:1024*1024,
      open(socket:ServerWebSocket<RealtimeData>){sockets.add(socket);setTimeout(()=>{if(!socket.data.authenticated&&socket.readyState===1)socket.close(4408,'Authentication timed out.');},5000);},
      message(socket:ServerWebSocket<RealtimeData>,message:string|Buffer){if(typeof message!=='string'){socket.close(1009,'Only UTF-8 JSON frames are supported.');return;}socket.data.queue=socket.data.queue.then(()=>processFrame(socket,message)).catch(error=>{if(!socket.data.authenticated){socket.close(error instanceof ApiError&&error.code==='forbidden'?4403:4401,'Authentication failed.');return;}if(error instanceof SyntaxError){socket.close(4400,'Malformed realtime JSON.');return;}send(socket,{type:'error',error:errorEnvelope(error,services.id('req')).error});});},
      pong(socket:ServerWebSocket<RealtimeData>){socket.data.lastActivity=services.now();},
      close(socket:ServerWebSocket<RealtimeData>){sockets.delete(socket);for(const remove of socket.data.terminalSubscriptions.values())remove();const user=socket.data.principal;const device=socket.data.deviceId;if(user&&device&&!Array.from(sockets).some(other=>other.data.principal?.userId===user.userId&&other.data.deviceId===device)){services.store.setMetadata('presence:'+device,{userId:user.userId,foreground:false,conversationId:null,updatedAtMs:services.now()});hooks.terminalDisconnect?.(user,device);hooks.voiceDisconnect?.(user.userId,device);}socket.data.token=null;}
    },
    revokeUser(userId:string){for(const socket of sockets)if(socket.data.principal?.userId===userId)socket.close(4403,'Account access was revoked.');},
    revokeSession(sessionId:string){for(const socket of sockets)if(socket.data.principal?.sessionId===sessionId)socket.close(4401,'Session was revoked.');},
    close(){clearInterval(heartbeat);unsubscribe();for(const socket of sockets)socket.close(1001,'Backend shutting down.');}
  };
}
