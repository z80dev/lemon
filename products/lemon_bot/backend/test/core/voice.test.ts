import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { cancelConversationVoice, createVoiceRoutes, createVoiceService } from '../../src/core/voice';
import { mediaFixture } from './attachments.fixture';

const nonce = 'voice_session_test_01';
describe('private voice session lifecycle', () => {
  test('one active call across devices, own registered device and Bot, and no group or channel voice', async () => {
    const f = await mediaFixture(); const routes = createVoiceRoutes(f.services); const service = createVoiceService(f.services);
    const start = routes.find(r => r.method === 'POST' && r.path === '/v1/voice/sessions')!;
    try {
      service.connect(f.user.userId, f.user.deviceId!);
      const session = start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId })) as P.VoiceSession;
      expect(session).toMatchObject({ state: 'active', muted: false, settings: f.bot.voice, feedback: null, endedAtMs: null, durationMs: 0, transcriptEntryIds: [] });
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId }))).toThrow();
      const secondDevice = { ...f.store.require<P.Device>('devices', f.user.deviceId!), id: 'device_second' }; f.store.put('devices', secondDevice);
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: secondDevice.id }, { ...f.user, deviceId: secondDevice.id }))).toThrow();
      const end = routes.find(r => r.path.endsWith('/end'))!;
      end.handler(f.context(end, { clientNonce: nonce }, f.user, { id: session.id }));
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.other.deviceId }))).toThrow();
      const secondBot = { ...f.bot, id: 'bot_second' }; f.store.put('bots', secondBot);
      f.store.put('conversations', f.services.update(f.conversation, { kind: 'group', botIds: [f.bot.id, secondBot.id] }));
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId }))).toThrow();
      f.store.put('conversations', f.services.update(f.conversation, { kind: 'channel' }));
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId }))).toThrow();
      f.store.put('bots', f.services.update(f.bot, { ownerUserId: f.other.userId }));
      f.store.put('conversations', f.conversation);
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId }))).toThrow();
      const member = f.services.auth.member(f.user.userId); f.store.put('members', f.services.update(member, { role: 'admin' }));
      expect(() => start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId }, { ...f.user, role: 'admin' }))).toThrow();
      f.store.put('bots', f.bot);
      expect((start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId })) as P.VoiceSession).state).toBe('active');
      service.endUser(f.user);
      f.store.put('conversations', f.services.update(f.conversation, { kind: 'task' }));
      expect((start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId })) as P.VoiceSession).state).toBe('active');
    } finally { service.close(); await f.close(); }
  });
  test('strict revisions/settings, terminal feedback, duration/transcript and one durable summary; work remains untouched', async () => {
    const f = await mediaFixture(); const routes = createVoiceRoutes(f.services); const service = createVoiceService(f.services);
    const start = routes.find(r => r.path === '/v1/voice/sessions')!;
    const patch = routes.find(r => r.method === 'PATCH')!; const end = routes.find(r => r.path.endsWith('/end'))!;
    try {
      service.connect(f.user.userId, f.user.deviceId!);
      let session = start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId })) as P.VoiceSession;
      expect(() => patch.handler(f.context(patch, { clientNonce: nonce, revision: session.revision, settings: { voiceId: 'default', speed: 3, language: null } }, f.user, { id: session.id }))).toThrow();
      expect(() => patch.handler(f.context(patch, { clientNonce: nonce, revision: session.revision, unknown: true }, f.user, { id: session.id }))).toThrow();
      const oldRevision = session.revision;
      session = patch.handler(f.context(patch, { clientNonce: nonce, revision: oldRevision, muted: true, settings: { voiceId: 'default', speed: 0.75, language: 'en-US' } }, f.user, { id: session.id })) as P.VoiceSession;
      expect(session.muted).toBe(true); expect(session.revision).toBe(oldRevision + 1);
      expect(() => patch.handler(f.context(patch, { clientNonce: nonce, revision: oldRevision, muted: false }, f.user, { id: session.id }))).toThrow();
      const utterance = f.services.entry(f.user, f.conversation.id, { kind: 'message', role: 'user', text: 'Voice input', streaming: false, attachmentIds: [] });
      const reply = f.services.entry(f.user, f.conversation.id, { kind: 'message', role: 'assistant', text: 'Reply', streaming: false, attachmentIds: [] });
      session = service.appendTranscript(session.id, [utterance.id, reply.id, utterance.id]);
      expect(session.transcriptEntryIds).toEqual([utterance.id, reply.id]);
      const invalid = f.services.entry(f.user, f.conversation.id, { kind: 'notice', severity: 'info', text: 'Not a turn', requestId: null });
      expect(() => service.appendTranscript(session.id, [invalid.id])).toThrow();
      const run: P.Run = f.services.resource('run', { conversationId: f.conversation.id, botId: f.bot.id, initiatorUserId: f.user.userId, clientNonce: nonce, status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null }); f.store.put('runs', run);
      f.advance(12345);
      const ended = end.handler(f.context(end, { clientNonce: nonce }, f.user, { id: session.id })) as P.VoiceSession;
      expect(ended.durationMs).toBe(12345); expect(ended.endedAtMs).toBe(ended.startedAtMs + 12345); expect(ended.state).toBe('ended');
      expect(end.handler(f.context(end, { clientNonce: nonce }, f.user, { id: session.id }))).toEqual(ended);
      const summaries = f.store.list<P.TranscriptEntry>('entries', e => e.kind === 'voice_call'); expect(summaries).toHaveLength(1);
      expect(summaries[0]!.targetedUserId).toBe(f.user.userId);
      expect(f.store.require<P.Run>('runs', run.id).status).toBe('running');
      expect(() => service.requireActive(f.user, session.id, f.conversation.id)).toThrow();
      expect(() => patch.handler(f.context(patch, { clientNonce: nonce, revision: ended.revision, muted: false }, f.user, { id: session.id }))).toThrow();
      const feedback = patch.handler(f.context(patch, { clientNonce: nonce, revision: ended.revision, feedback: 'good' }, f.user, { id: session.id })) as P.VoiceSession;
      expect(feedback.feedback).toBe('good'); const summary = f.store.require<P.TranscriptEntry>('entries', summaries[0]!.id);
      expect(summary.kind === 'voice_call' && summary.voiceSession.feedback).toBe('good'); expect(f.store.list<P.TranscriptEntry>('entries', e => e.kind === 'voice_call')).toHaveLength(1);
      expect(() => patch.handler(f.context(patch, { clientNonce: nonce, revision: feedback.revision, feedback: 'bad' }, f.other, { id: session.id }))).toThrow();
      expect(service.appendTranscript(session.id, [invalid.id])).toEqual(feedback);
    } finally { service.close(); await f.close(); }
  });
  test('disconnect grace persists across restart, reconnect cancels timeout, last connection alone fails call', async () => {
    const f = await mediaFixture(); const routes = createVoiceRoutes(f.services); let service = createVoiceService(f.services);
    const start = routes.find(r => r.path === '/v1/voice/sessions')!;
    try {
      service.connect(f.user.userId, f.user.deviceId!); service.connect(f.user.userId, f.user.deviceId!);
      const session = start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId })) as P.VoiceSession;
      service.disconnect(f.user.userId, f.user.deviceId!); f.advance(61000); service.sweep();
      expect(f.store.require<P.VoiceSession>('voiceSessions', session.id).state).toBe('active');
      service.disconnect(f.user.userId, f.user.deviceId!); f.advance(59000); service.sweep();
      expect(f.store.require<P.VoiceSession>('voiceSessions', session.id).state).toBe('active');
      service.connect(f.user.userId, f.user.deviceId!); f.advance(2000); service.sweep();
      expect(f.store.require<P.VoiceSession>('voiceSessions', session.id).state).toBe('active');
      service.disconnect(f.user.userId, f.user.deviceId!); f.advance(30000);
      service.close(); service = createVoiceService(f.services); f.advance(30001); service.sweep();
      const failed = f.store.require<P.VoiceSession>('voiceSessions', session.id);
      expect(failed.state).toBe('failed'); expect(failed.durationMs).toBe(f.services.now() - failed.startedAtMs); expect(f.store.list<P.TranscriptEntry>('entries', e => e.kind === 'voice_call')).toHaveLength(1);
      service.connect(f.user.userId, f.user.deviceId!); service.sweep();
      expect(f.store.require<P.VoiceSession>('voiceSessions', session.id)).toEqual(failed);
    } finally { service.close(); await f.close(); }
  });
  test('nonce replay preserves one created session; unconnected start times out without automatic retry', async () => {
    const f = await mediaFixture(); const routes = createVoiceRoutes(f.services); const service = createVoiceService(f.services);
    const start = routes.find(r => r.path === '/v1/voice/sessions')!;
    try {
      const context = f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId });
      const created = await f.services.mutations.execute(context, () => start.handler(context)) as P.VoiceSession;
      expect(await f.services.mutations.execute(context, () => start.handler(context))).toEqual(created); expect(f.store.list('voiceSessions')).toHaveLength(1);
      f.advance(60001); service.sweep();
      expect(f.store.require<P.VoiceSession>('voiceSessions', created.id).state).toBe('failed');
      expect(await f.services.mutations.execute(context, () => start.handler(context))).toEqual(created); expect(f.store.list('voiceSessions')).toHaveLength(1);
    } finally { service.close(); await f.close(); }
  });
  test('concurrent nonce-wrapped starts on different owned devices reserve exactly one active session', async () => {
    const f = await mediaFixture(); const routes = createVoiceRoutes(f.services); const service = createVoiceService(f.services);
    const start = routes.find(r => r.path === '/v1/voice/sessions')!;
    try {
      const second = { ...f.store.require<P.Device>('devices', f.user.deviceId!), id: 'device_second' }; f.store.put('devices', second);
      const firstContext = f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId });
      const secondContext = f.context(start, { clientNonce: 'voice_session_test_02', conversationId: f.conversation.id, deviceId: second.id }, { ...f.user, deviceId: second.id });
      const results = await Promise.allSettled([
        f.services.mutations.execute(firstContext, () => start.handler(firstContext)),
        f.services.mutations.execute(secondContext, () => start.handler(secondContext)),
      ]);
      expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1);
      expect(results.filter(result => result.status === 'rejected')).toHaveLength(1);
      expect(f.store.list<P.VoiceSession>('voiceSessions', session => session.state === 'active')).toHaveLength(1);
      const rejected = results.find(result => result.status === 'rejected');
      expect(rejected?.status === 'rejected' && rejected.reason.code).toBe('conflict');
    } finally { service.close(); await f.close(); }
  });
  test('confirmed room teardown cancels and erases only selected private voice sessions without appending a summary', async () => {
    const f = await mediaFixture(); const routes = createVoiceRoutes(f.services); const service = createVoiceService(f.services);
    const start = routes.find(r => r.path === '/v1/voice/sessions')!;
    try {
      service.connect(f.user.userId, f.user.deviceId!);
      const session = start.handler(f.context(start, { clientNonce: nonce, conversationId: f.conversation.id, deviceId: f.user.deviceId })) as P.VoiceSession;
      const otherBot = { ...f.bot, id: 'bot_other', ownerUserId: f.other.userId }; f.store.put('bots', otherBot);
      const otherRoom = { ...f.conversation, id: 'room_other', botIds: [otherBot.id], ownerUserId: f.other.userId }; f.store.put('conversations', otherRoom);
      service.connect(f.other.userId, f.other.deviceId!);
      const otherSession = start.handler(f.context(start, { clientNonce: 'voice_other_session_01', conversationId: otherRoom.id, deviceId: f.other.deviceId }, f.other)) as P.VoiceSession;
      const cancellations: P.VoiceSession[] = [];
      const unsubscribe = f.services.events.subscribe((event, audience) => {
        if (event.event === 'voice.upserted' && event.payload.id === session.id) {
          expect(audience.userIds).toEqual([f.user.userId]);
          cancellations.push(event.payload);
        }
      });
      f.advance(2500);
      expect(cancelConversationVoice(f.services, [f.conversation.id])).toBeUndefined();
      unsubscribe();
      expect(cancellations).toHaveLength(1); expect(cancellations[0]).toMatchObject({ state: 'failed', durationMs: 2500, endedAtMs: f.services.now() });
      expect(f.store.get('voiceSessions', session.id)).toBeNull();
      for (const key of ['voicePrincipal', 'voiceDisconnect', 'voiceSummary']) expect(f.store.metadata(`${key}:${session.id}`)).toBeNull();
      expect(f.store.require<P.VoiceSession>('voiceSessions', otherSession.id)).toEqual(otherSession);
      expect(f.store.list<P.TranscriptEntry>('entries', entry => entry.kind === 'voice_call')).toHaveLength(0);
      f.store.remove('conversations', f.conversation.id); f.advance(61000); service.sweep();
      expect(f.store.require<P.VoiceSession>('voiceSessions', otherSession.id).state).toBe('active');
      expect(cancelConversationVoice(f.services, [f.conversation.id])).toBeUndefined();
    } finally { service.close(); await f.close(); }
  });
});
