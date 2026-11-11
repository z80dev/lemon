import { describe, expect, test } from 'bun:test';
import { Store } from '../../src/core/store';
import { createEventService } from '../../src/core/events';
import { installHelpers } from '../../src/core/helpers';
import { botPresence, createExperienceService } from '../../src/core/experiences';
import { fixture as runtimeFixture } from '../runtime/fixture';
import type { BackendServices, Principal } from '../../src/core/services';
import type { Notification, RealtimeEvent, Run, TranscriptEntry } from '../../../contracts/protocol';
const alice:Principal={kind:'user',id:'alice',userId:'alice',workspaceId:'workspace',role:'member',sessionId:'session',botId:null,deviceId:null};
const bob:Principal={...alice,id:'bob',userId:'bob',role:'owner'};
function fixture(){
  const store=new Store(':memory:');store.put('members',{id:'member_alice',userId:'alice',enabled:true});store.put('members',{id:'member_bob',userId:'bob',enabled:true});
  // ACL is injected at the event boundary; authentication/role behavior is exercised in auth tests.
  const services={store,auth:{canRead(principal:Principal,_collection:string,entity:unknown){return !!entity&&typeof entity==='object'&&'userId' in entity&&entity.userId===principal.userId;},conversation(){throw new Error('invisible');},bot(){throw new Error('invisible');},machine(){throw new Error('invisible');}}} as unknown as BackendServices;
  installHelpers(services);services.events=createEventService(services);
  const notification=(userId:string):Notification=>services.resource('notification',{userId,conversationId:'room',botId:'bot',entryId:'entry',kind:'result',title:'Result',body:'Private result',requestId:null,readAtMs:null,dismissedAtMs:null,target:{kind:'entry',botId:'bot',conversationId:'room',entryId:'entry',taskConversationId:null},deepLink:'lemonbot://workspace/workspace/bot/bot?conversationId=room&entryId=entry'});
  return {store,services,notification};
}
function finalizationFixture(){
  const f=runtimeFixture();
  const run:Run=f.services.resource('run',{conversationId:f.conversation.id,botId:f.bot.id,initiatorUserId:f.alice.userId,clientNonce:'completion',status:'succeeded',error:null,startedAtMs:f.services.now(),completedAtMs:f.services.now(),routineRunId:null});
  const entry:Extract<TranscriptEntry,{kind:'message'}>=f.services.resource('entry',{conversationId:f.conversation.id,seq:1,timestampMs:f.services.now(),actor:{kind:'bot',id:f.bot.id,displayName:f.bot.name},clientNonce:null,batchId:null,replyToEntryId:null,runId:run.id,targetedUserId:null,reactions:[],kind:'message',role:'assistant',text:'pong',streaming:false,attachmentIds:[]});
  return {...f,run,entry};
}
describe('persisted realtime authorization and transaction boundary',()=>{
  test('private replay filters before delivery even for workspace owner and resumes across invisible gaps',()=>{
    const {store,services,notification}=fixture();const first=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});const second=services.events.emit('notification.upserted',notification('bob'),{userIds:['bob']});
    expect(services.events.replay(alice,'0').map(event=>event.seq)).toEqual([first.seq]);expect(services.events.replay(bob,'0').map(event=>event.seq)).toEqual([second.seq]);expect(services.events.cursor()).toBe(second.seq);
    const restarted=createEventService(services);expect(restarted.replay(alice,first.seq)).toEqual([]);store.close();
  });
  test('state and event rollback together and listeners observe only committed resources',()=>{
    const {store,services,notification}=fixture();const observed:string[]=[];services.events.subscribe(event=>{if(event.event!=='notification.upserted')throw new Error('Unexpected event');const record=store.get<Notification>('notifications',event.payload.id);expect(record).not.toBeNull();observed.push(event.seq);});
    const value=notification('alice');expect(()=>store.transaction(()=>{store.put('notifications',value);services.events.emit('notification.upserted',value,{userIds:['alice']});throw new Error('rollback');})).toThrow();expect(store.get('notifications',value.id)).toBeNull();expect(observed).toEqual([]);expect(services.events.replay(alice,'0')).toEqual([]);
    store.transaction(()=>{store.put('notifications',value);services.events.emit('notification.upserted',value,{userIds:['alice']});expect(observed).toEqual([]);});expect(observed.length).toBe(1);store.close();
  });
  test('membership revocation fences retained events and ACL tombstones survive deletion',()=>{
    const {store,services}=fixture();const tombstone=services.events.emit('conversation.deleted',{id:'deleted_private_room',deleted:true},{userIds:['alice'],conversationId:'deleted_private_room'});expect(services.events.replay(alice,'0').map(event=>event.seq)).toEqual([tombstone.seq]);expect(services.events.replay(bob,'0')).toEqual([]);
    store.put('members',{id:'member_alice',userId:'alice',enabled:false});expect(services.events.replay(alice,'0')).toEqual([]);store.close();
  });
  test('retention never reuses sequence and rejects old or future cursors without partial replay',()=>{
    const {store,services,notification}=fixture();const first=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});const second=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});store.db.query('DELETE FROM events WHERE seq=?').run(BigInt(first.seq));
    expect(()=>services.events.replay(alice,'0')).toThrow();expect(services.events.replay(alice,first.seq).map(event=>event.seq)).toEqual([second.seq]);store.db.exec('DELETE FROM events');const third=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});expect(BigInt(third.seq)).toBeGreaterThan(BigInt(second.seq));expect(()=>services.events.replay(alice,(BigInt(third.seq)+1n).toString())).toThrow();store.close();
  });
  test('preserves adjacent 64-bit sequences beyond the JavaScript safe integer boundary',()=>{
    const {store,services,notification}=fixture();services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});
    const base=9007199254740993n;store.db.query('UPDATE sqlite_sequence SET seq=? WHERE name=\'events\'').run(base);
    const first=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});const second=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});
    expect(first.seq).toBe((base+1n).toString());expect(second.seq).toBe((base+2n).toString());expect(services.events.cursor()).toBe(second.seq);
    expect(services.events.replay(alice,base.toString()).map(event=>event.seq)).toEqual([first.seq,second.seq]);expect(services.events.replay(alice,first.seq).map(event=>event.seq)).toEqual([second.seq]);store.close();
  });
  test('replays in integer order across decimal-width boundaries, including beyond safe integers',()=>{
    for(const base of [8n,98n,9999999999999998n]){
      const {store,services,notification}=fixture();services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});
      store.db.query('UPDATE sqlite_sequence SET seq=? WHERE name=\'events\'').run(base);
      const first=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});const second=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice']});
      expect(services.events.replay(alice,base.toString()).map(event=>event.seq)).toEqual([(base+1n).toString(),(base+2n).toString()]);
      expect(services.events.replay(alice,first.seq).map(event=>event.seq)).toEqual([second.seq]);store.close();
    }
  });
  test('desktop-only events exclude phones and recheck current device ownership on replay',()=>{
    const {store,services,notification}=fixture();store.put('devices',{id:'desktop',userId:'alice',platform:'macos'});store.put('devices',{id:'browser',userId:'alice',platform:'web'});store.put('devices',{id:'phone',userId:'alice',platform:'ios'});
    const event=services.events.emit('notification.upserted',notification('alice'),{userIds:['alice'],desktopOnly:true});
    expect(services.events.replay({...alice,deviceId:'desktop'},'0').map(value=>value.seq)).toEqual([event.seq]);expect(services.events.replay({...alice,deviceId:'browser'},'0').map(value=>value.seq)).toEqual([event.seq]);
    expect(services.events.replay({...alice,deviceId:'phone'},'0')).toEqual([]);expect(services.events.replay(alice,'0')).toEqual([]);expect(services.events.replay({...bob,deviceId:'desktop'},'0')).toEqual([]);
    store.put('devices',{id:'desktop',userId:'bob',platform:'macos'});expect(services.events.replay({...alice,deviceId:'desktop'},'0')).toEqual([]);store.remove('devices','browser');expect(services.events.replay({...alice,deviceId:'browser'},'0')).toEqual([]);store.close();
  });
  test('afterTransaction deduplicates hooks after every commit callback and drops rolled-back hooks',()=>{
    const store=new Store(':memory:');const observed:string[]=[];const after=()=>{observed.push('after');};
    try {
      store.transaction(()=>{
        store.afterTransaction(after);
        store.afterCommit(()=>{observed.push('first');});
        store.transaction(()=>{store.afterTransaction(after);store.afterCommit(()=>{observed.push('second');});});
        expect(observed).toEqual([]);
      });
      expect(observed).toEqual(['first','second','after']);
      expect(()=>store.transaction(()=>{store.afterTransaction(()=>{observed.push('rollback');});throw new Error('rollback');})).toThrow('rollback');
      store.transaction(()=>{store.afterCommit(()=>{observed.push('next');});});
      expect(observed).toEqual(['first','second','after','next']);
      store.afterTransaction(after);expect(observed.at(-1)).toBe('after');
    } finally {store.close();}
  });
  for(const nestedTransaction of [false,true]){
    test(`listener emission${nestedTransaction?' in a nested transaction':''} follows the entire committed batch`,()=>{
      const f=finalizationFixture();const observed:RealtimeEvent[]=[];const applied:RealtimeEvent[]=[];let cursor=0n;
      try {
        f.services.events.subscribe(event=>{
          observed.push(event);
          if(BigInt(event.seq)<=cursor)return;
          cursor=BigInt(event.seq);applied.push(event);
        });
        f.services.events.subscribe(event=>{
          if(event.event!=='entry.upserted')return;
          const emit=()=>{f.services.events.emit('bot.presence',botPresence(f.services,f.alice,f.bot),{userIds:[f.alice.userId]});};
          if(nestedTransaction)f.store.transaction(emit);else emit();
        });
        f.store.transaction(()=>{
          f.services.events.emit('entry.upserted',f.entry,{conversationId:f.conversation.id});
          f.services.events.emit('run.upserted',f.run,{botId:f.bot.id});
          f.services.events.emit('bot.upserted',f.bot,{botId:f.bot.id});
          expect(observed).toEqual([]);
        });
        expect(observed.map(event=>event.seq)).toEqual(['1','2','3','4']);
        expect(observed.map(event=>event.event)).toEqual(['entry.upserted','run.upserted','bot.upserted','bot.presence']);
        expect(applied).toEqual(observed);
      } finally {f.store.close();}
    });
  }
  test('rollback discards events from nested transactions and cannot leak them into the next drain',()=>{
    const f=finalizationFixture();const observed:RealtimeEvent[]=[];
    try {
      f.services.events.subscribe(event=>{observed.push(event);});
      expect(()=>f.store.transaction(()=>{
        f.services.events.emit('entry.upserted',f.entry);
        f.store.transaction(()=>{f.services.events.emit('run.upserted',f.run);});
        throw new Error('rollback');
      })).toThrow('rollback');
      expect(observed).toEqual([]);expect(f.services.events.replay(f.alice,'0')).toEqual([]);expect(f.services.events.cursor()).toBe('0');
      const committed=f.services.events.emit('bot.upserted',f.bot);
      expect(observed).toEqual([committed]);expect(committed.seq).toBe('1');
    } finally {f.store.close();}
  });
  test('depth-zero publication remains synchronous, including listener-originated emissions',()=>{
    const {store,services,notification}=fixture();const observed:string[]=[];
    try {
      services.events.subscribe(event=>{
        observed.push(`first:${event.seq}`);
        if(event.seq==='1')services.events.emit('notification.upserted',notification('alice'));
      });
      services.events.subscribe(event=>{observed.push(`second:${event.seq}`);});
      services.events.emit('notification.upserted',notification('alice'));
      expect(observed).toEqual(['first:1','second:1','first:2','second:2']);
    } finally {store.close();}
  });
  test('experience projections follow the final entry, terminal run and idle bot batch',()=>{
    const f=finalizationFixture();const lifecycle=createExperienceService(f.services);const observed:RealtimeEvent[]=[];
    try {
      f.store.put('runs',{...f.run,status:'running',completedAtMs:null});
      f.store.put('entries',{...f.entry,streaming:true});
      f.store.put('bots',{...f.bot,activity:'working',activeRunIds:[f.run.id]});
      // Production fan-out subscribes before the experience projection listener.
      f.services.events.subscribe(event=>{observed.push(event);});
      lifecycle.start();
      f.services.events.emit('run.upserted',f.store.require<Run>('runs',f.run.id));
      expect(observed.some(event=>event.event==='bot.presence'&&event.payload.status==='working')).toBe(true);
      const cursor=f.services.events.cursor();observed.length=0;
      f.store.transaction(()=>{
        f.store.put('entries',f.entry);f.services.events.emit('entry.upserted',f.entry,{conversationId:f.conversation.id,botId:f.bot.id});
        f.store.put('runs',f.run);f.services.events.emit('run.upserted',f.run,{conversationId:f.conversation.id,botId:f.bot.id});
        f.store.put('bots',f.bot);f.services.events.emit('bot.upserted',f.bot,{botId:f.bot.id});
      });
      expect(observed.map(event=>event.event)).toEqual(['entry.upserted','run.upserted','bot.upserted','bot.presence','activity.upserted']);
      expect(observed.map(event=>event.seq)).toEqual(Array.from({length:5},(_,index)=>(BigInt(cursor)+BigInt(index)+1n).toString()));
      const presence=observed.find(event=>event.event==='bot.presence');
      expect(presence?.payload).toMatchObject({botId:f.bot.id,status:'idle',currentRunId:null});
      expect(f.store.list('auditRecords')).toEqual([]);
    } finally {lifecycle.close();f.store.close();}
  });
});
