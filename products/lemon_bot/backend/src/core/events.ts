import { z } from 'zod';
import type { BackendServices, EventAudience, EventService, Principal } from './services';
import type { RealtimeEvent, ResourceEventPayloads } from '../../../contracts/protocol';
import { fail } from './errors';
import { Store } from './store';
const audienceSchema=z.object({userIds:z.array(z.string()).optional(),conversationId:z.string().optional(),botId:z.string().optional(),machineId:z.string().optional(),admin:z.boolean().optional(),public:z.boolean().optional()}).strict();
const collections:Record<string,string>={user:'users',workspace:'workspaces',member:'members',invite:'invites',device:'devices',machine:'machines',machine_invite:'machineInvites',bot:'bots',section:'sections',template:'templates',conversation:'conversations',composer:'composerDrafts',entry:'entries',run:'runs',attachment:'attachments',approval:'approvals',question:'questions',human_step:'humanSteps',secret_request:'secretRequests',draft:'drafts',skill:'skills',routine:'routines',routine_run:'routineRuns',memory:'memories',notification:'notifications',connector:'connectors',connector_auth:'connectorAuths',consent:'consents',channel:'channelBindings',voice:'voiceSessions',grant:'botGrants',activity:'activity',reminder:'reminders',preference_change:'preferenceChanges',milestone:'milestones',directory_group:'directoryGroups',group_policy:'groupPolicies',network_policy:'networkPolicies',policy_application:'policyApplications',egress:'egressRoutes',setup_manifest:'setupManifests',setup_run:'setupRuns',host_operation:'hostOperations',spend_limit:'spendLimits',export:'exports',channel_setup:'channelSetups',email_account:'emailAccounts',x_connection:'xConnections'};
export function createEventService(services:BackendServices):EventService {
  const listeners=new Set<(event:RealtimeEvent,audience:EventAudience)=>void>();
  const db=services.store.db;
  const watermark=()=>{const row=db.query('SELECT seq FROM sqlite_sequence WHERE name=\'events\'').safeIntegers(true).get() as {seq:bigint}|null; return String(row?.seq??0n);};
  const visible=(principal:Principal,event:RealtimeEvent,audience:EventAudience):boolean=>{
    const member=services.store.list<{userId:string;enabled:boolean;role?:string}>('members',item=>item.userId===principal.userId)[0];
    if(!member?.enabled) return false;
    if(audience.userIds && !audience.userIds.includes(principal.userId)) return false;
    if(audience.admin && member.role!=='owner'&&member.role!=='admin') return false;
    const [kind,action]=event.event.split('.');
    if(action==='deleted') return !!(audience.userIds?.includes(principal.userId)||audience.admin||audience.public);
    if(event.event==='conversation.left'){
      if(event.payload.userId===principal.userId&&audience.userIds?.includes(principal.userId))return true;
      try{services.auth.conversation(principal,event.payload.conversationId);return true;}catch{return false;}
    }
    try {
      if(audience.conversationId) services.auth.conversation(principal,audience.conversationId);
      if(audience.botId) services.auth.bot(principal,audience.botId);
      if(audience.machineId) services.auth.machine(principal,audience.machineId);
    } catch { return false; }
    if(kind==='policies'||kind==='governance') return member.role==='owner'||member.role==='admin'||audience.userIds?.includes(principal.userId)===true;
    if(kind==='workspace') return true;
    if(event.event==='bot.upserted'){try{services.auth.bot(principal,event.payload.id);}catch{return false;}}
    if(event.event==='conversation.upserted'){try{services.auth.conversation(principal,event.payload.id);}catch{return false;}}
    if(event.event==='entry.delta'||event.event==='conversation.read'||event.event==='composer.updated') {
      const payload=z.object({conversationId:z.string(),userId:z.string().optional()}).passthrough().safeParse(event.payload);
      if(!payload.success) return false;
      if(kind!=='entry'&&!audience.userIds) return false;
      try {services.auth.conversation(principal,payload.data.conversationId);return true;}catch{return false;}
    }
    if(event.event==='bot.presence') {const payload=z.object({botId:z.string()}).passthrough().safeParse(event.payload);if(!payload.success)return false;try{services.auth.bot(principal,payload.data.botId);return true;}catch{return false;}}
    const collection=collections[kind??''];
    if(!collection) return !!audience.userIds?.includes(principal.userId);
    return services.auth.canRead(principal,collection,event.payload);
  };
  return {
    emit<K extends keyof ResourceEventPayloads>(event:K,payload:ResourceEventPayloads[K],audience:EventAudience={}):RealtimeEvent {
      audienceSchema.parse(audience);
      const timestampMs=services.now();
      const receipt=db.query('INSERT INTO events(event,payload,audience,timestamp_ms) VALUES(?,?,?,?)').safeIntegers(true).run(event,JSON.stringify(payload),JSON.stringify(audience),timestampMs);
      // The generic event key and its indexed payload originate from the same typed call.
      const envelope={type:'event',seq:String(receipt.lastInsertRowid),event,payload,timestampMs} as RealtimeEvent;
      const publish=()=>{for(const listener of listeners){try{listener(envelope,audience);}catch{services.audit(null,'realtime.publish',envelope.seq,'failed',{event:envelope.event});}}};
      if(services.store instanceof Store) services.store.afterCommit(publish);else publish();
      return envelope;
    },
    cursor:watermark,
    earliestCursor() {const row=db.query('SELECT MIN(seq) AS seq FROM events').safeIntegers(true).get() as {seq:bigint|null};return String(row.seq??BigInt(watermark())+1n);},
    visible,
    replay(principal,cursor,conversationIds=[]) {
      if(!/^\d+$/.test(cursor))fail('invalid_request','Realtime cursor is invalid.');
      const start=BigInt(cursor);const max=BigInt(watermark());const firstRow=db.query('SELECT MIN(seq) AS seq FROM events').safeIntegers(true).get() as {seq:bigint|null};const earliest=firstRow.seq===null?max+1n:firstRow.seq;
      if(start<earliest-1n)fail('cursor_expired','Realtime history expired; fetch a new snapshot.');
      if(start>max)fail('invalid_request','Realtime cursor is ahead of this workspace.');
      const rows=db.query('SELECT seq,event,payload,audience,timestamp_ms FROM events WHERE seq>? AND seq<=? ORDER BY seq').safeIntegers(true).all(start,max) as {seq:bigint;event:RealtimeEvent['event'];payload:string;audience:string;timestamp_ms:bigint}[];
      const result:RealtimeEvent[]=[];
      for(const row of rows) {
        const audience=audienceSchema.parse(JSON.parse(row.audience));
        // Persisted events are written only through the typed emit boundary above.
        const event={type:'event',seq:String(row.seq),event:row.event,payload:JSON.parse(row.payload),timestampMs:Number(row.timestamp_ms)} as RealtimeEvent;
        if(!visible(principal,event,audience))continue;
        if(conversationIds.length&&audience.conversationId&&!conversationIds.includes(audience.conversationId))continue;
        if(conversationIds.length&&event.event.startsWith('entry.')&&typeof event.payload==='object'&&event.payload!==null&&'conversationId' in event.payload&&typeof event.payload.conversationId==='string'&&!conversationIds.includes(event.payload.conversationId))continue;
        result.push(event);
      }
      return result;
    },
    subscribe(listener) {listeners.add(listener);return()=>{listeners.delete(listener);};}
  };
}
