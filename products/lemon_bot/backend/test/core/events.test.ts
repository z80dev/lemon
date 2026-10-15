import { describe, expect, test } from 'bun:test';
import { Store } from '../../src/core/store';
import { createEventService } from '../../src/core/events';
import { installHelpers } from '../../src/core/helpers';
import type { BackendServices, Principal } from '../../src/core/services';
import type { Notification } from '../../../contracts/protocol';
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
});
