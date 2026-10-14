import { afterEach, describe, expect, test } from 'bun:test';
import { createDecipheriv, createECDH, createPrivateKey, hkdfSync, verify } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from '../../src/core/services';
import { apnsToken, createPushServices, encryptWebPush, isPublicPushAddress, validatePushRegistration, vapidToken } from '../../src/integrations/push';
import { createPrivateCodec } from '../../src/core/config';
import { closeFixture, entityStore, fixture as channelFixture } from './channels-fixture';

const now = 1_791_940_000_000;
const scalar = (n: number) => { const b=Buffer.alloc(32);b[31]=n;return b; };
function keyPair(n: number) { const ecdh=createECDH('prime256v1');ecdh.setPrivateKey(scalar(n));const pub=ecdh.getPublicKey();const key=createPrivateKey({format:'jwk',key:{kty:'EC',crv:'P-256',x:pub.subarray(1,33).toString('base64url'),y:pub.subarray(33).toString('base64url'),d:scalar(n).toString('base64url')}});return {ecdh,pub,key}; }
const receiver=keyPair(2),vapid=keyPair(3);
const subscription: Extract<P.PushRegistration,{kind:'web_push'}> = {kind:'web_push',endpoint:'https://fcm.googleapis.com/fcm/send/fixture',keys:{p256dh:receiver.pub.toString('base64url'),auth:Buffer.alloc(16,7).toString('base64url')}};
const vapidEnv = { LEMON_BOT_VAPID_PUBLIC_KEY:vapid.pub.toString('base64url'),LEMON_BOT_VAPID_PRIVATE_KEY:scalar(3).toString('base64url'),LEMON_BOT_VAPID_SUBJECT:'mailto:operator@example.test' };
const publicDNS=async()=>[{address:'142.250.1.1',family:4}];
/** Independently decrypt using node HKDF rather than the production HMAC expansion helper. */
function decrypt(body: Uint8Array, privateKey=scalar(2), auth=Buffer.alloc(16,7)): Buffer {
  const b=Buffer.from(body),salt=b.subarray(0,16),length=b[20]!,sender=b.subarray(21,21+length),ecdh=createECDH('prime256v1');ecdh.setPrivateKey(privateKey);
  const shared=ecdh.computeSecret(sender),ikm=Buffer.from(hkdfSync('sha256',shared,auth,Buffer.concat([Buffer.from('WebPush: info\0'),ecdh.getPublicKey(),sender]),32));
  const key=Buffer.from(hkdfSync('sha256',ikm,salt,Buffer.from('Content-Encoding: aes128gcm\0'),16)),nonce=Buffer.from(hkdfSync('sha256',ikm,salt,Buffer.from('Content-Encoding: nonce\0'),12));
  const decoder=createDecipheriv('aes-128-gcm',key,nonce);decoder.setAuthTag(b.subarray(-16));const plain=Buffer.concat([decoder.update(b.subarray(21+length,-16)),decoder.final()]);expect(plain[plain.length-1]).toBe(2);return plain.subarray(0,-1);
}
interface SessionSecretFixture { id: string; revoked: boolean }
interface FixtureMetadata { get(key: string): unknown; set(key: string, value: unknown): void }
interface PushFixture { services: BackendServices; metadata: FixtureMetadata; events: string[]; audits: unknown[]; notification: P.Notification; advance(ms:number): void; change<T extends { id: string }>(collection: string, id: string, mutate: (value: T) => void): void }
const openFixtures: BackendServices[] = [];
afterEach(() => { for (const services of openFixtures.splice(0)) closeFixture(services); });
function fixture(): PushFixture {
  const principal: Principal = { kind: 'user', id: 'user', userId: 'user', workspaceId: 'workspace', role: 'member', sessionId: 'device', botId: null, deviceId: 'device' };
  const state = channelFixture(entityStore(), principal), services = state.services;
  openFixtures.push(services); state.setClock(now);
  let clock = now; const events: string[] = [], audits: unknown[] = [];
  const metadata: FixtureMetadata = { get: key => services.store.metadata(key), set: (key, value) => services.store.setMetadata(key, value) };
  const codec = createPrivateCodec(new Uint8Array(32).fill(9));
  services.encrypt = codec.encrypt; services.decrypt = codec.decrypt;
  const user = services.store.require<P.User>('users', 'user');
  services.store.put('users', { ...user, notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true } });
  const member = services.store.require<P.Member>('members', 'user');
  services.store.remove('members', member.id); services.store.put('members', { ...member, id: 'member' });
  services.store.remove('bots', state.bot.id);
  services.store.put('bots', { ...state.bot, id: 'bot', mainConversationId: 'conversation' });
  const conversation = services.store.require<P.Conversation>('conversations', state.bot.mainConversationId);
  services.store.remove('conversations', conversation.id);
  services.store.put('conversations', { ...conversation, id: 'conversation', botIds: ['bot'], leadBotId: 'bot' });
  const entry: P.TranscriptEntry = { ...services.resource('entry', {}), id: 'entry', conversationId: 'conversation', seq: 1, timestampMs: now, actor: { kind: 'system', id: null, displayName: 'System' }, clientNonce: null, batchId: null, replyToEntryId: null, runId: null, targetedUserId: null, reactions: [], kind: 'message', role: 'user', text: 'Private notification fixture', streaming: false, attachmentIds: [] };
  services.store.put('entries', entry);
  for (const id of ['device', 'otherDevice']) {
    const device: P.Device = { ...services.resource('device', {}), id, userId: 'user', platform: 'web', name: id, appVersion: 'test', pushEnabled: true, lastSeenAtMs: now };
    const session: P.AuthSession = { ...services.resource('session', {}), id, userId: 'user', deviceId: id, expiresAtMs: now + 30 * 86400000, lastSeenAtMs: now, current: true };
    services.store.put('devices', device); services.store.put('authSessions', session); services.store.put<SessionSecretFixture>('sessionSecrets', { id, revoked: false });
  }
  const access = services.auth;
  services.auth = {
    ...access,
    member(userId) { const member = services.store.list<P.Member>('members', value => value.userId === userId)[0]; if (!member) throw new Error('Member not found.'); return member; },
    conversation(actor, id) { if (id !== 'conversation') throw new Error('invisible'); return access.conversation(actor, id); },
    bot(actor, id, manage) {
      if (id !== 'bot') throw new Error('invisible');
      const bot = access.bot(actor, id, manage), sidebar = services.store.metadata<Pick<P.Bot['sidebar'], 'hidden' | 'notificationsEnabled'>>('sidebar');
      return sidebar ? { ...bot, sidebar: { ...bot.sidebar, ...sidebar } } : bot;
    },
    canRead(actor, collection, entity) {
      if (metadata.get('deny') === true) return false;
      if (collection === 'entries' && entity && typeof entity === 'object' && 'conversationId' in entity && typeof entity.conversationId === 'string') {
        try { access.conversation(actor, entity.conversationId); return true; } catch { return false; }
      }
      return access.canRead(actor, collection, entity);
    },
    machine(actor, id, manage) { if (actor.role === 'member') throw new Error('host authority revoked'); return access.machine(actor, id, manage); },
  };
  const policy = services.integrations.effectivePolicy;
  services.integrations.effectivePolicy = async (actor, botId) => { const result = await policy(actor, botId); return { ...result, productAccess: result.productAccess && metadata.get('denyAccess') !== true }; };
  const eventService = services.events;
  services.events = { ...eventService, emit(event, payload, audience) { events.push(event); return eventService.emit(event, payload, audience); } };
  services.audit = (actor, action, targetId, outcome, details, requestId) => {
    audits.push([actor, action, targetId, outcome, details, requestId]);
    const record: P.AuditRecord = services.resource('audit', { actor: { kind: actor?.kind === 'user' ? 'user' : actor?.kind === 'bot' ? 'bot' : 'system', id: actor?.id ?? null, displayName: 'Push fixture actor' }, action, resourceType: 'push', resourceId: targetId, outcome, metadata: details ?? {}, requestId: requestId ?? 'push-request' });
    return services.store.put('auditRecords', record);
  };
  metadata.set('devicePush:device', services.encrypt(subscription)); metadata.set('devicePushRegisteredAt:device', now);
  const notification: P.Notification = { ...services.resource('notification', {}), id: 'notification', userId: 'user', conversationId: 'conversation', botId: 'bot', entryId: 'entry', kind: 'question', title: 'secret fixture-key', body: 'private terminal output and password', requestId: null, readAtMs: null, dismissedAtMs: null, target: { kind: 'entry', botId: 'bot', conversationId: 'conversation', taskConversationId: null, entryId: 'entry' }, deepLink: 'lemonbot://unsafe?token=credential' };
  return {
    services, metadata, events, audits, notification,
    advance(ms) { clock += ms; state.setClock(clock); },
    change<T extends { id: string }>(collection: string, id: string, mutate: (value: T) => void) { const value = services.store.require<T>(collection, id); mutate(value); services.store.put(collection, value); },
  };
}

describe('RFC 8291 and ES256 fixtures',()=>{
  test('matches RFC 8291 Appendix A ciphertext and decrypts independently',()=>{
    const sub:Extract<P.PushRegistration,{kind:'web_push'}>={kind:'web_push',endpoint:subscription.endpoint,keys:{p256dh:'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',auth:'BTBZMqHH6r4Tts7J_aSIgg'}};
    const body=Buffer.from(encryptWebPush(Buffer.from('When I grow up, I want to be a watermelon'),sub,{salt:Buffer.from('DGv6ra1nlYgDCS1FRnbzlw','base64url'),privateKey:Buffer.from('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw','base64url')}));
    expect(body.subarray(86).toString('base64url')).toBe('8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ');expect(body.readUInt32BE(16)).toBe(4096);
    expect(decrypt(body,Buffer.from('q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94','base64url'),Buffer.from(sub.keys.auth,'base64url')).toString()).toBe('When I grow up, I want to be a watermelon');
  });
  test('tamper, wrong receiver and oversized payload are rejected',()=>{
    const body=Buffer.from(encryptWebPush(Buffer.from('private'),subscription,{salt:Buffer.alloc(16,4),privateKey:scalar(1)}));expect(decrypt(body).toString()).toBe('private');const changed=Buffer.from(body);changed[90]=changed[90]!^1;expect(()=>decrypt(changed)).toThrow();expect(()=>decrypt(body,scalar(4))).toThrow();expect(()=>encryptWebPush(new Uint8Array(3994),subscription)).toThrow('one encrypted record');
  });
  test('APNs uses ES256 P1363 signature and current issuance; VAPID pins exact audience and expiry',()=>{
    const signing=keyPair(1),pem=signing.key.export({format:'pem',type:'pkcs8'}).toString(),jwt=apnsToken('KEY1234567','TEAM123456',pem,now),parts=jwt.split('.');
    expect(JSON.parse(Buffer.from(parts[0]!,'base64url').toString())).toEqual({alg:'ES256',kid:'KEY1234567'});expect(JSON.parse(Buffer.from(parts[1]!,'base64url').toString())).toEqual({iss:'TEAM123456',iat:Math.floor(now/1000)});expect(Buffer.from(parts[2]!,'base64url').length).toBe(64);expect(verify('sha256',Buffer.from(`${parts[0]}.${parts[1]}`),{key:signing.key,dsaEncoding:'ieee-p1363'},Buffer.from(parts[2]!,'base64url'))).toBe(true);
    const v=vapidToken('https://fcm.googleapis.com',vapidEnv.LEMON_BOT_VAPID_SUBJECT,vapidEnv.LEMON_BOT_VAPID_PUBLIC_KEY,vapidEnv.LEMON_BOT_VAPID_PRIVATE_KEY,now).split('.');expect(JSON.parse(Buffer.from(v[1]!,'base64url').toString())).toEqual({aud:'https://fcm.googleapis.com',sub:'mailto:operator@example.test',exp:Math.floor(now/1000)+43200});expect(verify('sha256',Buffer.from(`${v[0]}.${v[1]}`),{key:vapid.key,dsaEncoding:'ieee-p1363'},Buffer.from(v[2]!,'base64url'))).toBe(true);
    expect(()=>vapidToken('https://fcm.googleapis.com','mailto:operator@example.test',receiver.pub.toString('base64url'),scalar(3).toString('base64url'),now)).toThrow('do not match');
  });
});

describe('push registration SSRF and delivery authorization',()=>{
  test('only public DNS on exact allowlisted HTTPS origins with valid receiver keys',async()=>{
    await validatePushRegistration(subscription,{resolve:publicDNS});
    for(const endpoint of ['http://fcm.googleapis.com/send','https://fcm.googleapis.com.evil.test/send','https://fcm.googleapis.com:444/send','https://user:secret@fcm.googleapis.com/send','https://127.0.0.1/send']) await expect(validatePushRegistration({...subscription,endpoint},{resolve:publicDNS})).rejects.toMatchObject({code:'invalid_request'});
    await expect(validatePushRegistration(subscription,{resolve:async()=>[{address:'127.0.0.1',family:4}]})).rejects.toThrow('prohibited');await expect(validatePushRegistration(subscription,{resolve:async()=>[{address:'142.250.1.1',family:4},{address:'10.0.0.1',family:4}]})).rejects.toThrow('prohibited');
    await expect(validatePushRegistration({...subscription,keys:{...subscription.keys,auth:'invalid'}},{resolve:publicDNS})).rejects.toMatchObject({code:'invalid_request'});
    for(const address of ['127.0.0.1','10.1.1.1','100.64.0.1','169.254.169.254','172.16.0.1','192.168.1.1','198.18.1.1','203.0.113.1','::1','fc00::1','fe80::1','::ffff:127.0.0.1','2001:db8::1','2002:7f00:1::'])expect(isPublicPushAddress(address)).toBe(false);expect(isPublicPushAddress('2001:4860:4860::8888')).toBe(true);
  });
  test('APNs topic/environment allowlists and 32-byte token are mandatory',async()=>{
    const registration:Extract<P.PushRegistration,{kind:'apns'}>={kind:'apns',token:'ab'.repeat(32),topic:'test.lemon',environment:'sandbox'};const env={LEMON_BOT_APNS_TOPICS:'test.lemon',LEMON_BOT_APNS_ENVIRONMENTS:'sandbox'};await validatePushRegistration(registration,{env});await expect(validatePushRegistration({...registration,topic:'other'},{env})).rejects.toThrow();await expect(validatePushRegistration({...registration,environment:'production'},{env})).rejects.toThrow();await expect(validatePushRegistration({...registration,token:'short'},{env})).rejects.toThrow();
  });
  test('encrypted exact private payload, current installation and 410 invalidation; diagnostics contain no credentials',async()=>{
    const f=fixture();let sends=0;const push=createPushServices(f.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async(url,address,headers,body)=>{sends++;expect(url.origin).toBe('https://fcm.googleapis.com');expect(address.address).toBe('142.250.1.1');expect(headers['Content-Encoding']).toBe('aes128gcm');const payload=JSON.parse(decrypt(body).toString()) as P.PushPayload;expect(payload).toMatchObject({version:1,notificationId:'notification',workspaceId:'workspace',target:f.notification.target});expect(payload.deepLink).toBe('lemonbot://workspace/workspace/bot/bot?conversationId=conversation&entryId=entry');expect(JSON.stringify(payload)).not.toContain('secret');expect(JSON.stringify(payload)).not.toContain('private terminal');expect(JSON.stringify(payload)).not.toContain('credential');return{status:410};}});
    expect(push.providerCapabilities()).toMatchObject({webPush:true,apns:false,vapidPublicKey:vapidEnv.LEMON_BOT_VAPID_PUBLIC_KEY});await push.emitProviderNotifications(f.notification);expect(sends).toBe(1);expect(f.metadata.get('devicePush:device')).toBeNull();expect(f.services.store.get<P.Device>('devices','device')!.pushEnabled).toBe(false);expect(f.events).toContain('device.upserted');expect(JSON.stringify(f.audits)).not.toContain('fixture-key');expect(JSON.stringify(f.audits)).not.toContain('Authorization');
  });
  test('foreground suppression is same-device/same-room only and expires after sixty seconds',async()=>{
    const f=fixture();f.metadata.set('devicePush:otherDevice',f.services.encrypt(subscription));f.metadata.set('presence:device',{userId:'user',foreground:true,conversationId:'conversation',updatedAtMs:now});let sends=0;const push=createPushServices(f.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async()=>{sends++;return{status:201};}});await push.emitProviderNotifications(f.notification);expect(sends).toBe(1);f.advance(60_001);await push.emitProviderNotifications(f.notification);expect(sends).toBe(3);
  });
  test('revoked/expired sessions, disabled member/device/preferences/sidebar and invisible entries deny delivery',async()=>{
    for(const change of [
      (f:PushFixture)=>{f.change<SessionSecretFixture>('sessionSecrets', 'device', value => { value.revoked = true; });},
      (f:PushFixture)=>{f.change<P.AuthSession>('authSessions', 'device', value => { value.expiresAtMs = now; });},
      (f:PushFixture)=>{f.change<P.Member>('members', 'member', value => { value.enabled = false; });},
      (f:PushFixture)=>{f.change<P.Device>('devices', 'device', value => { value.pushEnabled = false; });},
      (f:PushFixture)=>{f.change<P.User>('users', 'user', value => { value.notifications.enabled = false; });},
      (f:PushFixture)=>{f.metadata.set('sidebar',{hidden:true,notificationsEnabled:true});},
      (f:PushFixture)=>{f.metadata.set('deny',true);},
      (f:PushFixture)=>{f.metadata.set('denyAccess',true);},
    ]) {const f=fixture();change(f);let sends=0;const push=createPushServices(f.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async()=>{sends++;return{status:201};}});await push.emitProviderNotifications(f.notification);expect(sends).toBe(0);}
  });
  test('revocation during DNS resolution prevents dispatch, and replacement registration survives old invalidation',async()=>{
    const f=fixture();let sends=0;const push=createPushServices(f.services,{env:vapidEnv,resolve:async()=>{f.change<SessionSecretFixture>('sessionSecrets', 'device', value => { value.revoked = true; });return publicDNS();},sendWebPush:async()=>{sends++;return{status:201};}});await push.emitProviderNotifications(f.notification);expect(sends).toBe(0);
    const fresh=fixture();const deliver=createPushServices(fresh.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async()=>{fresh.metadata.set('devicePush:device',fresh.services.encrypt(subscription));return{status:410};}});await deliver.emitProviderNotifications(fresh.notification);expect(fresh.metadata.get('devicePush:device')).not.toBeNull();expect(fresh.services.store.get<P.Device>('devices','device')!.pushEnabled).toBe(true);
  });
  test('token invalidation atomically preserves device edits made while the provider request was in flight',async()=>{
    const f=fixture();const push=createPushServices(f.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async()=>{const current=f.services.store.get<P.Device>('devices','device')!;f.services.store.put('devices',{...current,name:'Updated name',revision:current.revision+1,updatedAtMs:now+1});return{status:410};}});await push.emitProviderNotifications(f.notification);expect(f.services.store.get<P.Device>('devices','device')).toMatchObject({name:'Updated name',pushEnabled:false,revision:3});expect(f.metadata.get('devicePushRegisteredAt:device')).toBeNull();
  });
  test('selected-group revocation during DNS and inconsistent target IDs fence private delivery',async()=>{
    const f=fixture();let sends=0;const push=createPushServices(f.services,{env:vapidEnv,resolve:async()=>{f.metadata.set('denyAccess',true);return publicDNS();},sendWebPush:async()=>{sends++;return{status:201};}});await push.emitProviderNotifications(f.notification);expect(sends).toBe(0);
    const other=fixture();if(other.notification.target.kind==='entry')other.notification.target.entryId='foreign-entry';const denied=createPushServices(other.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async()=>{sends++;return{status:201};}});await denied.emitProviderNotifications(other.notification);expect(sends).toBe(0);
    const options={env:{}};expect(createPushServices(other.services,options)).not.toBe(createPushServices(other.services,options));
  });
  test('privacy preferences and current host-management role are rechecked after DNS awaits',async()=>{
    const f=fixture();let sends=0;const push=createPushServices(f.services,{env:vapidEnv,resolve:async()=>{f.change<P.User>('users', 'user', value => { value.notifications.previews = false; });return publicDNS();},sendWebPush:async(_url,_address,_headers,body)=>{sends++;expect(JSON.parse(decrypt(body).toString()).title).toBe('Lemon Bot');return{status:201};}});await push.emitProviderNotifications(f.notification);expect(sends).toBe(1);
    const host=fixture();host.change<P.Member>('members', 'member', value => { value.role = 'owner'; });Object.assign(host.notification,{kind:'machine',botId:null,conversationId:null,entryId:null,target:{kind:'machine',machineId:'machine',botId:null}});
    const denied=createPushServices(host.services,{env:vapidEnv,resolve:async()=>{host.change<P.Member>('members', 'member', value => { value.role = 'member'; });return publicDNS();},sendWebPush:async()=>{sends++;return{status:201};}});await denied.emitProviderNotifications(host.notification);expect(sends).toBe(1);
  });
  test('provider redirects/transient errors never clear subscriptions or leak provider response',async()=>{
    for(const status of [302,401,403,429,500,503]){const f=fixture();const push=createPushServices(f.services,{env:vapidEnv,resolve:publicDNS,sendWebPush:async()=>({status,reason:'secret fixture-token'})});await push.emitProviderNotifications(f.notification);expect(f.metadata.get('devicePush:device')).not.toBeNull();expect(JSON.stringify(f.audits)).not.toContain('fixture-token');}
  });
});

test('APNs fixtures route HTTP2 topic/environment, renew JWT, ignore stale 410 and invalidate bad token',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'lemon-apns-fixture-')),path=join(directory,'fixture.p8');writeFileSync(path,keyPair(1).key.export({format:'pem',type:'pkcs8'}),{mode:0o600});
  try{
    const f=fixture();f.metadata.set('devicePush:device',f.services.encrypt({kind:'apns',token:'ab'.repeat(32),topic:'test.lemon',environment:'sandbox'}));let sends=0;const issuance:number[]=[];
    const push=createPushServices(f.services,{env:{LEMON_BOT_APNS_PRIVATE_KEY_PATH:path,LEMON_BOT_APNS_KEY_ID:'KEY1234567',LEMON_BOT_APNS_TEAM_ID:'TEAM123456',LEMON_BOT_APNS_TOPICS:'test.lemon'},sendAPNs:async(origin,path,headers,body)=>{
      sends++;expect(origin).toBe('https://api.sandbox.push.apple.com');expect(path).toBe(`/3/device/${'ab'.repeat(32)}`);expect(headers['apns-topic']).toBe('test.lemon');expect(headers['apns-push-type']).toBe('alert');expect(headers.authorization.startsWith('bearer ')).toBe(true);issuance.push(JSON.parse(Buffer.from(headers.authorization.split('.')[1]!,'base64url').toString()).iat);const payload=JSON.parse(Buffer.from(body).toString());expect(payload.aps.alert.title).toBe('Your Bot needs attention');expect(payload.aps.sound).toBe('default');expect(JSON.stringify(payload)).not.toContain('secret');return sends===1?{status:410,timestamp:now-1000}:{status:400,reason:'BadDeviceToken'};
    }});
    expect(push.providerCapabilities().apns).toBe(true);await push.emitProviderNotifications(f.notification);expect(f.metadata.get('devicePush:device')).not.toBeNull();f.advance(50*60_000);await push.emitProviderNotifications(f.notification);expect(issuance[1]!-issuance[0]!).toBe(3000);expect(f.metadata.get('devicePush:device')).toBeNull();
  }finally{rmSync(directory,{recursive:true,force:true});}
});
