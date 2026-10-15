import { afterEach, describe, expect, test } from 'bun:test';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, HttpClient, Principal, RequestContext } from '../../src/core/services';
import { changePcmSpeed, createAudioRoutes, createAudioServices, googleAssertion, inspectAudio, pcmWave } from '../../src/integrations/audio';
import { additionalOwner, closeFixture, fixture as channelFixture } from './channels-fixture';

const now = 1_791_940_000_000;
const principal: Principal = { kind: 'user', id: 'user', userId: 'user', workspaceId: 'workspace', role: 'member', sessionId: 'auth', botId: null, deviceId: 'device' };
const resource = { revision: 1, createdAtMs: now, updatedAtMs: now };
const nonce = '0123456789abcdef';
const voice: P.VoiceSettings = { voiceId: 'default', speed: 1, language: 'en-US' };
const fixtures: BackendServices[] = [];
afterEach(() => { for (const services of fixtures.splice(0)) closeFixture(services); });
function fixture() {
  const pcm = Buffer.alloc(48000); for (let i = 0; i < pcm.length; i += 2) pcm.writeInt16LE(i % 100 < 50 ? 3000 : -3000, i);
  const wave = pcmWave(pcm);
  let captured: Uint8Array | null = null;
  const attachment: P.Attachment = { ...resource, id: 'attachment', ownerUserId: 'user', conversationId: 'conversation', botId: null, filename: 'capture.wav', mime: 'audio/wav', size: wave.length, sha256: 'sha', width: null, height: null, durationMs: 1000, source: 'upload', state: 'ready', preview: 'audio', provenance: { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: null } };
  const base = channelFixture(undefined, principal);
  const { services } = base; base.setClock(now); fixtures.push(services);
  const session: P.VoiceSession = new Proxy({ ...resource, id: 'voice', userId: 'user', deviceId: 'device', conversationId: 'conversation', settings: voice, state: 'active', startedAtMs: now, endedAtMs: null, durationMs: 0, transcriptEntryIds: [], muted: false, feedback: null } satisfies P.VoiceSession, {
    set(target, property, value) { const changed = Reflect.set(target, property, value); services.store.put('voiceSessions', target); return changed; },
  });
  services.store.put('voiceSessions', session); services.store.put('attachments', attachment);
  services.store.setMetadata(`bytes:${attachment.id}`, Buffer.from(wave).toString('base64'));
  const bot: P.Bot = { ...base.bot, id: 'bot', voice, machineId: 'machine', mainConversationId: 'conversation' };
  const conversation: P.Conversation = { ...services.store.require<P.Conversation>('conversations', base.bot.mainConversationId), id: 'conversation', botIds: [bot.id], leadBotId: bot.id };
  services.store.put('bots', bot); services.store.put('conversations', conversation);
  let conversations = 0, productAccess = true;
  const authorizeConversation = services.auth.conversation;
  services.auth.conversation = (who, id) => { conversations++; return authorizeConversation(who, id); };
  const effectivePolicy = services.integrations.effectivePolicy;
  services.integrations.effectivePolicy = async (who, botId) => ({ ...await effectivePolicy(who, botId), productAccess });
  services.attachments.create = async (who, bytes, metadata) => {
    if (metadata.conversationId) services.auth.conversation(who, metadata.conversationId);
    if (metadata.botId) services.auth.bot(who, metadata.botId);
    const created: P.Attachment = { ...attachment, id: 'speech', ownerUserId: who.userId, source: metadata.source ?? 'upload', provenance: metadata.provenance ?? attachment.provenance, durationMs: inspectAudio(bytes).durationMs, conversationId: metadata.conversationId ?? null, botId: metadata.botId ?? null, filename: metadata.filename, mime: metadata.mime ?? 'audio/wav', size: bytes.length };
    services.store.put('attachments', created); services.store.setMetadata(`bytes:${created.id}`, Buffer.from(bytes).toString('base64'));
    captured = bytes;
    return created;
  };
  services.attachments.download = (who, id) => {
    const value = services.auth.attachment(who, id);
    return { url: `https://product.test/v1/downloads/${id}`, expiresAtMs: now + 60_000, filename: value.filename, mime: value.mime, size: value.size };
  };
  const events: string[] = [];
  const emit = services.events.emit;
  services.events.emit = (event, payload, audience) => { events.push(event); return emit(event, payload, audience); };
  return { services, attachment, session, wave, events, captured: () => captured, conversations: () => conversations, setProductAccess: (enabled: boolean) => { productAccess = enabled; } };
}
const fakeFetch = (fn: (url: string, init: RequestInit) => Response | Promise<Response>): HttpClient => async (input, init) => fn(input instanceof Request ? input.url : String(input), init ?? {});

describe('curated voice catalog', () => {
  test('returns provider choices and default without any network or synthesis', async () => {
    const f = fixture();
    const request: HttpClient = async () => { throw new Error('Catalog must not call a provider'); };
    for (const provider of ['openai', 'elevenlabs', 'google'] as const) {
      const audio = createAudioServices(f.services, { env: { LEMON_BOT_TTS_PROVIDER: provider, LEMON_BOT_OPENAI_API_KEY: 'private', LEMON_BOT_ELEVENLABS_API_KEY: 'private' }, fetch: request });
      const catalog = await audio.voiceCatalog(principal);
      expect(catalog.provider).toBe(provider);
      expect(catalog.configured).toBe(provider !== 'google');
      expect(catalog.voices[0]).toEqual({ id: 'default', name: 'Provider default', languages: [] });
      expect(catalog.voices.length).toBeGreaterThan(1);
      expect(new Set(catalog.voices.map(voice => voice.id)).size).toBe(catalog.voices.length);
      if (provider === 'google') expect(catalog.voices[1]?.languages).toEqual(['en-US']);
    }
    expect(f.captured()).toBeNull(); expect(f.events).toEqual([]);
  });
  test('unconfigured/unknown providers are honest and product access is enforced', async () => {
    const f = fixture();
    for (const provider of [undefined, 'unknown', 'openai']) {
      const catalog = await createAudioServices(f.services, { env: { LEMON_BOT_TTS_PROVIDER: provider } }).voiceCatalog(principal);
      expect(catalog.configured).toBe(false);
      expect(catalog.provider).toBe(provider === 'openai' ? 'openai' : null);
      if (provider !== 'openai') expect(catalog.voices).toHaveLength(1);
    }
    f.setProductAccess(false);
    await expect(createAudioServices(f.services, { env: {} }).voiceCatalog(principal)).rejects.toMatchObject({ code: 'policy_denied' });
    const route = createAudioRoutes(f.services, { env: {} }).find(route => route.path === '/v1/audio/voices')!;
    expect(route.method).toBe('GET'); expect(route.auth).toBe('member');
    expect(() => route.handler({ user: null } as RequestContext)).toThrow('Authentication required');
  });
});

describe('bounded genuine audio containers', () => {
  test('sniffs bytes and measures PCM WAV, MP3, MP4, live WebM and Opus', () => {
    const f = fixture(); expect(inspectAudio(f.wave)).toEqual({ mime: 'audio/wav', extension: 'wav', durationMs: 1000 });
    const streamingWave=Buffer.from(f.wave);streamingWave.writeUInt32LE(0xffffffff,4);streamingWave.writeUInt32LE(0xffffffff,40);expect(inspectAudio(streamingWave).durationMs).toBe(1000);
    const mp3 = Buffer.alloc(417); mp3.writeUInt32BE(0xfffb9000); expect(inspectAudio(mp3).durationMs).toBe(26);
    const box = (name: string, data: Buffer) => { const b = Buffer.alloc(8 + data.length); b.writeUInt32BE(b.length); b.write(name, 4); data.copy(b,8); return b; };
    const mdhd = Buffer.alloc(24); mdhd.writeUInt32BE(1000,12); mdhd.writeUInt32BE(1000,16); const hdlr = Buffer.alloc(12); hdlr.write('soun',8);
    const mp4 = Buffer.concat([box('ftyp', Buffer.from('M4A ')), box('moov', box('trak', box('mdia', Buffer.concat([box('mdhd',mdhd),box('hdlr',hdlr)])))),box('mdat',Buffer.from([1]))]);
    expect(inspectAudio(mp4)).toEqual({ mime: 'audio/mp4', extension: 'm4a', durationMs: 1000 });
    const ebml = (tag: string, data: Buffer) => Buffer.concat([Buffer.from(tag,'hex'),Buffer.from([0x80 | data.length]),data]);
    const webm = Buffer.concat([ebml('1a45dfa3', Buffer.alloc(0)), ebml('18538067', Buffer.concat([ebml('1654ae6b',ebml('ae',ebml('86',Buffer.from('A_OPUS')))),ebml('1f43b675',Buffer.concat([ebml('e7',Buffer.from([0])),ebml('a3',Buffer.from([0x81,0,0,0x80,0x98,0x01]))]))]))]);
    expect(inspectAudio(webm)).toEqual({ mime: 'audio/webm', extension: 'webm', durationMs: 20 });
    const page = (data: Buffer, granule: bigint) => { const b = Buffer.alloc(28 + data.length); b.write('OggS'); b.writeBigUInt64LE(granule,6); b[26]=1; b[27]=data.length; data.copy(b,28); return b; };
    const head = Buffer.alloc(19); head.write('OpusHead'); head[8]=1; head[9]=1;
    expect(inspectAudio(Buffer.concat([page(head,0n),page(Buffer.from([0x98,1]),48000n)])).durationMs).toBe(1000);
  });
  test('rejects empty, truncated, unsupported and >ten-minute audio', () => {
    const f = fixture(); expect(() => inspectAudio(new Uint8Array())).toThrow('empty'); expect(() => inspectAudio(f.wave.slice(0,-1))).toThrow('truncated'); expect(() => inspectAudio(Buffer.from('pretend audio'))).toThrow();
    expect(() => inspectAudio(pcmWave(new Uint8Array(9_600_032), 8000))).toThrow('ten minutes'); expect(() => inspectAudio(new Uint8Array(25*1024*1024+1))).toThrow('25 MiB');
  });
});

describe('authorized provider audio', () => {
  test('OpenAI multipart STT returns reviewable text and never sends chat', async () => {
    const f = fixture(); let requests = 0;
    const audio = createAudioServices(f.services, { env: { LEMON_BOT_STT_PROVIDER: 'openai', LEMON_BOT_OPENAI_API_KEY: 'fixture-key' }, fetch: fakeFetch((url, init) => {
      requests++; expect(url).toBe('https://api.openai.com/v1/audio/transcriptions'); expect(init.redirect).toBe('error'); expect(init.body).toBeInstanceOf(FormData); const form = init.body as FormData; expect(form.get('model')).toBe('whisper-1'); expect(form.get('language')).toBe('en'); expect(form.get('file')).toBeInstanceOf(Blob);
      return Response.json({ text: 'Review this text.', language: 'english', duration: 1, segments: [{ text: 'Review this text.', start: 0, end: 1 }] });
    }) });
    expect(await audio.transcribe(principal, { clientNonce: nonce, attachmentId: 'attachment', voiceSessionId: 'voice', language: 'en-US' })).toEqual({ text: 'Review this text.', language: 'english', durationMs: 1000, segments: [{ text: 'Review this text.', startMs: 0, endMs: 1000 }] }); expect(requests).toBe(1); expect(f.events).toEqual([]);
  });
  test('Deepgram request and timing are provider compatible', async () => {
    const f = fixture(); const audio = createAudioServices(f.services, { env: { LEMON_BOT_STT_PROVIDER: 'deepgram', LEMON_BOT_DEEPGRAM_API_KEY: 'fixture' }, fetch: fakeFetch((url, init) => {
      expect(url).toContain('https://api.deepgram.com/v1/listen?'); expect(url).toContain('detect_language=true'); expect(new Headers(init.headers).get('Authorization')).toBe('Token fixture'); expect(Buffer.from(init.body as Uint8Array)).toEqual(Buffer.from(f.wave));
      return Response.json({ metadata: { duration: 1 }, results: { channels: [{ detected_language: 'en', alternatives: [{ transcript: 'hello', words: [{ word: 'hello', start: 0, end: 1 }] }] }] } });
    }) }); expect((await audio.transcribe(principal, { clientNonce: nonce, attachmentId: 'attachment' })).segments).toEqual([{ text:'hello',startMs:0,endMs:1000 }]);
  });
  test('OpenAI speech persists exact nonempty provider audio with authorized download', async () => {
    const f = fixture(); const audio = createAudioServices(f.services, { env: { LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture' }, fetch: fakeFetch((_url,init) => { expect(JSON.parse(String(init.body))).toMatchObject({ input:'Actual words',voice:'alloy',speed:1,response_format:'wav' }); return new Response(Buffer.from(f.wave)); }) });
    const result = await audio.speech(principal,{clientNonce:nonce,text:'Actual words',voice,conversationId:'conversation',voiceSessionId:'voice'});
    expect(f.captured()).toEqual(f.wave); expect(result.attachment).toMatchObject({ source:'tts',durationMs:1000,conversationId:'conversation' }); expect(result.download.url).toContain('/downloads/speech');
  });
  test('OpenAI honors documented custom voice objects and language pronunciation instructions', async () => {
    const f=fixture();const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch((_url,init)=>{const request=JSON.parse(String(init.body));expect(request.voice).toEqual({id:'voice_fixture'});expect(request.instructions).toContain('fr-FR');expect(request.input).toBe('Bonjour');return new Response(Buffer.from(f.wave));})});
    await audio.speech(principal,{clientNonce:nonce,text:'Bonjour',voice:{...voice,voiceId:'voice_fixture',language:'fr-FR'}});
  });
  test('OpenAI transcribes actual Ogg Opus with sniffed MIME and extension, not upload labels', async () => {
    const f=fixture();const page=(data:Buffer,granule:bigint)=>{const b=Buffer.alloc(28+data.length);b.write('OggS');b.writeBigUInt64LE(granule,6);b[26]=1;b[27]=data.length;data.copy(b,28);return b;},head=Buffer.alloc(19);head.write('OpusHead');head[8]=1;head[9]=1;const ogg=Buffer.concat([page(head,0n),page(Buffer.from([0x98,1]),48000n)]);f.services.attachments.bytes=async()=>ogg;
    const audio=createAudioServices(f.services,{env:{LEMON_BOT_STT_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch((_url,init)=>{const form=init.body as FormData,file=form.get('file') as File;expect(file.type).toBe('audio/ogg');expect(file.name).toBe('audio.ogg');return Response.json({text:'words',duration:1,language:'english',segments:[]});})});expect((await audio.transcribe(principal,{clientNonce:nonce,attachmentId:'attachment'})).text).toBe('words');
  });
  test('ElevenLabs wraps genuine PCM rather than fabricating silent audio', async () => {
    const f = fixture(), pcm = Buffer.from(f.wave).subarray(44); const audio = createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'elevenlabs',LEMON_BOT_ELEVENLABS_API_KEY:'fixture'},fetch:fakeFetch((url,init) => { expect(url).toContain('?output_format=pcm_24000'); expect(new Headers(init.headers).get('xi-api-key')).toBe('fixture'); expect(JSON.parse(String(init.body)).voice_settings.speed).toBe(1); return new Response(pcm); })});
    const result = await audio.speech(principal,{clientNonce:nonce,text:'Words',voice}); expect(f.captured()).toEqual(f.wave); expect(result.attachment.durationMs).toBe(1000);
  });
  test('ElevenLabs full contract speed keeps real samples and maps provider range compatibly', async () => {
    const f=fixture(),pcm=Buffer.from(f.wave).subarray(44);
    expect(changePcmSpeed(pcm,1)).toBe(pcm);expect(changePcmSpeed(pcm,0.5).length).toBe(pcm.length*2);expect(changePcmSpeed(pcm,2).length).toBe(pcm.length/2);
    for (const speed of [0.5,2]) {
      let providerSpeed=0;
      const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'elevenlabs',LEMON_BOT_ELEVENLABS_API_KEY:'fixture'},fetch:fakeFetch((_url,init)=>{providerSpeed=JSON.parse(String(init.body)).voice_settings.speed;return new Response(pcm);})});
      const result=await audio.speech(principal,{clientNonce:nonce,text:'words',voice:{...voice,speed}});
      expect(providerSpeed).toBe(speed===0.5?0.7:1.2);expect(result.attachment.durationMs).toBe(Math.round(Math.floor(24000/(speed/providerSpeed))/24));expect(Buffer.from(f.captured()!).subarray(44).some(byte=>byte!==0)).toBe(true);
    }
  });
  test('ACL, active ownership, session-conversation binding and strict request validation precede provider', async () => {
    const f=fixture(); let calls=0; const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture',LEMON_BOT_STT_PROVIDER:'openai'},fetch:fakeFetch(()=>{calls++;return new Response(Buffer.from(f.wave));})});
    await expect(audio.transcribe({...principal,userId:'other'},{clientNonce:nonce,attachmentId:'attachment'})).rejects.toMatchObject({code:'not_found'});
    f.session.userId='other'; await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice,voiceSessionId:'voice'})).rejects.toMatchObject({code:'not_found'});
    f.session.userId='user'; f.session.state='ended'; await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice,voiceSessionId:'voice'})).rejects.toMatchObject({code:'conflict'});
    f.session.state='active'; f.session.conversationId='another'; await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice,conversationId:'conversation',voiceSessionId:'voice'})).rejects.toThrow();
    await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice,unknown:true})).rejects.toMatchObject({code:'invalid_request'}); expect(calls).toBe(0);
  });
  test('foreign administrators cannot synthesize or replay another owner’s Bot/context and never contact the audio provider', async () => {
    const f = fixture(), owned = f.services.store.require<P.Bot>('bots', 'bot');
    const foreign = additionalOwner(f.services, owned, 'foreign', 'owner');
    let calls = 0;
    const audio = createAudioServices(f.services, { env: { LEMON_BOT_TTS_PROVIDER: 'openai', LEMON_BOT_OPENAI_API_KEY: 'fixture' }, fetch: fakeFetch(() => { calls++; return new Response(Buffer.from(f.wave)); }) });
    await expect(audio.speech(foreign.principal, { clientNonce: nonce, text: 'private words', voice, conversationId: 'conversation' })).rejects.toMatchObject({ code: 'not_found' });
    await expect(audio.speech(principal, { clientNonce: nonce, text: 'private words', voice }, { botId: foreign.bot.id, runId: null, machineId: foreign.bot.machineId, sourceEntryId: null, generatedAtMs: null })).rejects.toMatchObject({ code: 'not_found' });
    await expect(audio.authorizeReplay(foreign.principal, { clientNonce: nonce }, 'preview', owned.id)).rejects.toMatchObject({ code: 'not_found' });
    expect(calls).toBe(0); expect(f.captured()).toBeNull();
  });
  test('selected-group product access denial blocks providers and revocation fences speech persistence', async () => {
    const f=fixture();let calls=0;const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_STT_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch(()=>{calls++;f.setProductAccess(false);return new Response(Buffer.from(f.wave));})});
    f.setProductAccess(false);await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice})).rejects.toMatchObject({code:'policy_denied'});await expect(audio.transcribe(principal,{clientNonce:nonce,attachmentId:'attachment'})).rejects.toMatchObject({code:'policy_denied'});expect(calls).toBe(0);
    f.setProductAccess(true);await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice})).rejects.toMatchObject({code:'policy_denied'});expect(calls).toBe(1);expect(f.captured()).toBeNull();
  });
  test('trusted memo provenance reaches initial creation; HTTP callers cannot supply it', async () => {
    const f=fixture();const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch(()=>new Response(Buffer.from(f.wave)))});
    const provenance:P.DeliverableProvenance={botId:'bot',runId:'run',machineId:'machine',sourceEntryId:'entry',generatedAtMs:0};
    const result=await audio.speech(principal,{clientNonce:nonce,text:'words',voice,conversationId:'conversation'},provenance);expect(result.attachment.provenance).toEqual({...provenance,generatedAtMs:now});expect(result.attachment.source).toBe('tts');
    await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice,provenance})).rejects.toMatchObject({code:'invalid_request'});
    await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice},{...provenance,machineId:'foreign'})).rejects.toMatchObject({code:'invalid_request'});
  });
  test('nonce receipt replay rechecks ownership and group access without redispatching an ended call', async () => {
    const f=fixture();f.session.state='ended';const audio=createAudioServices(f.services,{env:{}}),body={clientNonce:nonce,text:'words',voice,conversationId:'conversation',voiceSessionId:'voice'};
    await audio.authorizeReplay(principal,body,'speech');await expect(audio.speech(principal,body)).rejects.toMatchObject({code:'conflict'});
    await expect(audio.authorizeReplay({...principal,userId:'other'},body,'speech')).rejects.toMatchObject({code:'not_found'});f.setProductAccess(false);await expect(audio.authorizeReplay(principal,body,'speech')).rejects.toMatchObject({code:'policy_denied'});expect(f.captured()).toBeNull();
  });
  test('explicit provider options stay isolated and unknown enum values never enter public inventory', () => {
    const f=fixture(),options={env:{}};expect(createAudioServices(f.services,options)).not.toBe(createAudioServices(f.services,options));const audio=createAudioServices(f.services,{env:{LEMON_BOT_STT_PROVIDER:'secret-value',LEMON_BOT_TTS_PROVIDER:'private-value'}});expect(audio.inventory().every(item=>item.provider===null&&!item.configured)).toBe(true);
  });
  test('missing credentials are precise; malformed/status/empty provider responses never create an attachment', async () => {
    const f=fixture(); expect(createAudioServices(f.services,{env:{}}).providerCapabilities()).toEqual({stt:false,tts:false}); await expect(createAudioServices(f.services,{env:{}}).speech(principal,{clientNonce:nonce,text:'words',voice})).rejects.toMatchObject({code:'capability_unavailable'});
    for (const response of [new Response('secret-provider-error',{status:401}),new Response(new Uint8Array()),new Response('not audio'),new Response(Buffer.from(pcmWave(new Uint8Array(48000))))]) { const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch(()=>response)}); await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice})).rejects.toThrow(); } expect(f.captured()).toBeNull();
    const invalid=createAudioServices(f.services,{env:{LEMON_BOT_STT_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch(()=>Response.json({text:'text',duration:'bad'}))}); await expect(invalid.transcribe(principal,{clientNonce:nonce,attachmentId:'attachment'})).rejects.toMatchObject({code:'upstream_unavailable'});
  });
  test('provider deadline abort is sanitized and never persists bytes', async () => {
    const f=fixture(); const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},timeoutMs:1,fetch:fakeFetch((_url,init)=>{const {promise,reject}=Promise.withResolvers<Response>(); init.signal?.addEventListener('abort',()=>reject(new Error('secret diagnostic')));return promise;})});
    await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice})).rejects.toMatchObject({code:'upstream_unavailable',message:'Audio provider request failed or timed out.'}); expect(f.captured()).toBeNull();
  });
  test('preview uses fixed non-sensitive sample without conversation or run creation', async () => {
    const f=fixture(); const routes=createAudioRoutes(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'openai',LEMON_BOT_OPENAI_API_KEY:'fixture'},fetch:fakeFetch((_url,init)=>{expect(JSON.parse(String(init.body)).input).toBe('Hello, I’m your Lemon Bot teammate. Ready when you are.');return new Response(Buffer.from(f.wave));})});
    const route=routes.find(r=>r.path==='/v1/bots/:id/voice/preview')!;
    const context: RequestContext = { request: new Request('https://product.example/v1/bots/bot/voice/preview', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ clientNonce: nonce }) }), user: principal, params: { id: 'bot' }, query: new URLSearchParams(), body: { clientNonce: nonce }, services: f.services, requestId: 'audio_preview', route, nonceResourceIds: [] };
    const result=await route.handler(context) as P.SpeechResult; expect(result.attachment.conversationId).toBeNull(); expect(result.attachment.botId).toBe('bot'); expect(f.conversations()).toBe(0);
  });
});

test('Google RS256 service-account assertion, real token exchange, expiry refresh and LINEAR16 persistence', async () => {
  const {privateKey,publicKey}=generateKeyPairSync('rsa',{modulusLength:2048}); const account={client_email:'fixture@example.test',private_key:privateKey.export({format:'pem',type:'pkcs8'}).toString(),project_id:'fixture-project'};
  const assertion=googleAssertion(account,now),parts=assertion.split('.'); expect(verify('RSA-SHA256',Buffer.from(`${parts[0]}.${parts[1]}`),publicKey,Buffer.from(parts[2]!,'base64url'))).toBe(true);
  expect(JSON.parse(Buffer.from(parts[1]!,'base64url').toString())).toMatchObject({iss:account.client_email,aud:'https://oauth2.googleapis.com/token',iat:Math.floor(now/1000),exp:Math.floor(now/1000)+3600});
  const directory=mkdtempSync(join(tmpdir(),'lemon-audio-fixture-')); const path=join(directory,'service-account.json'); writeFileSync(path,JSON.stringify(account),{mode:0o600});
  try {
    const f=fixture(); let clock=now,exchanges=0,syntheses=0,detections=0,rejectToken=false,denyDetection=false,expectedLanguage='en-US'; const texts:string[]=[]; f.services.now=()=>clock;
    const audio=createAudioServices(f.services,{env:{LEMON_BOT_TTS_PROVIDER:'google',LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH:path},fetch:fakeFetch((url,init)=>{
      if(url==='https://oauth2.googleapis.com/token'){exchanges++;expect((init.body as URLSearchParams).get('grant_type')).toBe('urn:ietf:params:oauth:grant-type:jwt-bearer');return Response.json({access_token:'fixture-token',token_type:'Bearer',expires_in:3600});}
      if(url==='https://translate.googleapis.com/v3/projects/fixture-project/locations/global:detectLanguage'){detections++;expect(JSON.parse(String(init.body))).toEqual({content:'Bonjour',mimeType:'text/plain'});return denyDetection?new Response('private-project-error',{status:403}):Response.json({languages:[{languageCode:'fr',confidence:0.99}]});}
      syntheses++;const request=JSON.parse(String(init.body));texts.push(request.input.text);expect(Buffer.byteLength(request.input.text)).toBeLessThanOrEqual(4800);expect(url).toBe('https://texttospeech.googleapis.com/v1/text:synthesize');expect(new Headers(init.headers).get('Authorization')).toBe('Bearer fixture-token'); expect(request.voice.name).toBeUndefined();expect(request.voice.languageCode).toBe(expectedLanguage);expect(request.audioConfig.audioEncoding).toBe('LINEAR16');if(rejectToken){rejectToken=false;return new Response('private-token-error',{status:401});}return Response.json({audioContent:Buffer.from(f.wave).toString('base64')});
    })});
    await Promise.all([audio.speech(principal,{clientNonce:nonce,text:'words',voice}),audio.speech(principal,{clientNonce:'0123456789abcdeg',text:'words',voice})]); expect(exchanges).toBe(1); clock+=3_550_000;await audio.speech(principal,{clientNonce:nonce,text:'words',voice});expect(exchanges).toBe(2);expect(f.captured()).toEqual(f.wave);
    const before=syntheses,longText='界'.repeat(3000);const combined=await audio.speech(principal,{clientNonce:nonce,text:longText,voice});expect(syntheses-before).toBe(2);expect(texts.slice(-2).join('')).toBe(longText);expect(combined.attachment.durationMs).toBe(2000);expect(Buffer.from(f.captured()!).subarray(44)).toEqual(Buffer.concat([Buffer.from(f.wave).subarray(44),Buffer.from(f.wave).subarray(44)]));
    rejectToken=true;await expect(audio.speech(principal,{clientNonce:nonce,text:'words',voice})).rejects.toMatchObject({code:'upstream_unavailable'});expect(exchanges).toBe(2);await audio.speech(principal,{clientNonce:nonce,text:'words',voice});expect(exchanges).toBe(3);
    expectedLanguage='fr';await audio.speech(principal,{clientNonce:nonce,text:'Bonjour',voice:{...voice,language:null}});expect(detections).toBe(1);denyDetection=true;await expect(audio.speech(principal,{clientNonce:nonce,text:'Bonjour',voice:{...voice,language:null}})).rejects.toMatchObject({code:'capability_unavailable',message:'Google automatic-language speech requires Cloud Translation API and language-detection permission.'});
    const call=fixture();let utterances=0;const live=createAudioServices(call.services,{env:{LEMON_BOT_TTS_PROVIDER:'google',LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH:path},fetch:fakeFetch((url)=>{if(url==='https://oauth2.googleapis.com/token')return Response.json({access_token:'fixture-token',token_type:'Bearer',expires_in:3600});utterances++;call.session.state='ended';return new Response(JSON.stringify({audioContent:Buffer.from(call.wave).toString('base64')}),{headers:{'Content-Type':'application/json'}});})});
    await expect(live.speech(principal,{clientNonce:nonce,text:'界'.repeat(3000),voice,conversationId:'conversation',voiceSessionId:'voice'})).rejects.toMatchObject({code:'conflict'});expect(utterances).toBe(1);expect(call.captured()).toBeNull();
  } finally {rmSync(directory,{recursive:true,force:true});}
});
