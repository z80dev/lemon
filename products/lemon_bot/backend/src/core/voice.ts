import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from './services';
import { fail } from './errors';
import { id, mutation, parse, principal, update, voice, z } from './validation';

const settings = voice.extend({ language: z.string().regex(/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/).max(64).nullable() });
const start = mutation.extend({ conversationId: id, deviceId: id, settings: settings.optional() });
const patch = update.extend({ muted: z.boolean().optional(), settings: settings.optional(), feedback: z.enum(['good', 'bad']).optional() });
const GRACE_MS = 60_000;

export interface VoiceService {
  connect(userId: string, deviceId: string): void;
  disconnect(userId: string, deviceId: string): void;
  appendTranscript(sessionId: string, entryIds: string[]): P.VoiceSession;
  requireActive(user: Principal, sessionId: string, conversationId: string): P.VoiceSession;
  endUser(user: Principal): void;
  sweep(): void;
  close(): void;
}
const instances = new WeakMap<BackendServices, VoiceService>();

export function createVoiceService(services: BackendServices): VoiceService {
  const existing = instances.get(services);
  if (existing) return existing;
  const { store } = services;
  const connections = new Map<string, number>();
  const key = (userId: string, deviceId: string) => `${userId}:${deviceId}`;
  const deadlineKey = (sessionId: string) => `voiceDisconnect:${sessionId}`;
  const emit = (session: P.VoiceSession) => services.events.emit('voice.upserted', session, { userIds: [session.userId] });
  const own = (user: Principal, sessionId: string): P.VoiceSession => {
    const session = store.require<P.VoiceSession>('voiceSessions', sessionId);
    if (user.kind !== 'user' || session.userId !== user.userId) fail('forbidden', 'Voice session belongs to another user.');
    services.auth.conversation(user, session.conversationId);
    return session;
  };
  const finish = (session: P.VoiceSession, state: 'ended' | 'failed', user: Principal): P.VoiceSession => store.transaction(() => {
    const current = store.require<P.VoiceSession>('voiceSessions', session.id);
    if (current.state !== 'active') return current;
    const endedAtMs = services.now();
    const ended = services.update(current, { state, endedAtMs, durationMs: Math.max(0, endedAtMs - current.startedAtMs) });
    store.put('voiceSessions', ended);
    const entry = services.entry(user, ended.conversationId, { kind: 'voice_call', voiceSession: ended });
    store.setMetadata(`voiceSummary:${ended.id}`, entry.id);
    store.setMetadata(deadlineKey(ended.id), null);
    emit(ended);
    return ended;
  });
  const syncSummary = (session: P.VoiceSession) => {
    const entryId = store.metadata<string>(`voiceSummary:${session.id}`);
    if (!entryId) return;
    const entry = store.get<P.TranscriptEntry>('entries', entryId);
    if (entry?.kind !== 'voice_call') return;
    const updated = services.update(entry, { voiceSession: session });
    store.put('entries', updated);
    services.events.emit('entry.upserted', updated, { conversationId: session.conversationId });
  };
  const service: VoiceService = {
    connect(userId, deviceId) {
      const connectionKey = key(userId, deviceId);
      connections.set(connectionKey, (connections.get(connectionKey) ?? 0) + 1);
      for (const session of store.list<P.VoiceSession>('voiceSessions', s => s.userId === userId && s.deviceId === deviceId && s.state === 'active')) store.setMetadata(deadlineKey(session.id), null);
    },
    disconnect(userId, deviceId) {
      const connectionKey = key(userId, deviceId);
      const count = connections.get(connectionKey) ?? 0;
      if (count > 1) { connections.set(connectionKey, count - 1); return; }
      connections.delete(connectionKey);
      for (const session of store.list<P.VoiceSession>('voiceSessions', s => s.userId === userId && s.deviceId === deviceId && s.state === 'active')) store.setMetadata(deadlineKey(session.id), services.now() + GRACE_MS);
    },
    appendTranscript(sessionId, entryIds) {
      return store.transaction(() => {
        const session = store.require<P.VoiceSession>('voiceSessions', sessionId);
        if (session.state !== 'active') return session;
        for (const entryId of entryIds) {
          const entry = store.require<P.TranscriptEntry>('entries', entryId);
          if (entry.kind !== 'message' || entry.conversationId !== session.conversationId || entry.timestampMs < session.startedAtMs) fail('invalid_request', 'Entry is not part of this voice conversation.');
        }
        const transcriptEntryIds = [...new Set([...session.transcriptEntryIds, ...entryIds])];
        if (transcriptEntryIds.length === session.transcriptEntryIds.length) return session;
        const changed = services.update(session, { transcriptEntryIds });
        store.put('voiceSessions', changed);
        emit(changed);
        return changed;
      });
    },
    endUser(user) {
      for (const session of store.list<P.VoiceSession>('voiceSessions', s => s.userId === user.userId && s.state === 'active')) finish(session, 'ended', user);
    },
    requireActive(user, sessionId, conversationId) {
      service.sweep();
      const session = own(user, sessionId);
      if (session.state !== 'active' || session.conversationId !== conversationId) fail('conflict', 'Voice session is not active in this conversation.');
      return session;
    },
    sweep() {
      for (const session of store.list<P.VoiceSession>('voiceSessions', s => s.state === 'active')) {
        const deadline = store.metadata<number>(deadlineKey(session.id));
        if (deadline !== null && deadline <= services.now()) {
          const user = store.metadata<Principal>(`voicePrincipal:${session.id}`);
          if (user) finish(session, 'failed', user);
        }
      }
    },
    close() { clearInterval(timer); instances.delete(services); },
  };
  // Restart is a disconnected device, never an automatic microphone/call restart.
  for (const session of store.list<P.VoiceSession>('voiceSessions', s => s.state === 'active')) {
    if (store.metadata<number>(deadlineKey(session.id)) === null) store.setMetadata(deadlineKey(session.id), services.now() + GRACE_MS);
  }
  const timer = setInterval(() => service.sweep(), 1_000);
  timer.unref();
  instances.set(services, service);
  routeActions.set(services, { own, finish, emit, syncSummary, connections });
  return service;
}

/** Server-only conversation lifecycle hook; the caller has confirmed the exact deletion/reset room scope. */
export function cancelConversationVoice(services: BackendServices, conversationIds: string[]): void {
  const selected = new Set(conversationIds);
  if (!selected.size) return;
  services.store.transaction(() => {
    for (const session of services.store.list<P.VoiceSession>('voiceSessions', value => selected.has(value.conversationId))) {
      if (session.state === 'active') {
        const endedAtMs = services.now();
        const cancelled = services.update(session, { state: 'failed' as const, endedAtMs, durationMs: Math.max(0, endedAtMs - session.startedAtMs) });
        services.events.emit('voice.upserted', cancelled, { userIds: [session.userId] });
      }
      // The owning conversation lifecycle erases transcript entries; never append a summary into a removed room.
      services.store.remove('voiceSessions', session.id);
      services.store.setMetadata(`voicePrincipal:${session.id}`, null);
      services.store.setMetadata(`voiceDisconnect:${session.id}`, null);
      services.store.setMetadata(`voiceSummary:${session.id}`, null);
    }
  });
}


interface Actions {
  own(user: Principal, sessionId: string): P.VoiceSession;
  finish(session: P.VoiceSession, state: 'ended' | 'failed', user: Principal): P.VoiceSession;
  emit(session: P.VoiceSession): void;
  syncSummary(session: P.VoiceSession): void;
  connections: Map<string, number>;
}
const routeActions = new WeakMap<BackendServices, Actions>();

export function createVoiceRoutes(services: BackendServices): Route[] {
  const service = createVoiceService(services);
  const actions = routeActions.get(services)!;
  return [
    { method: 'POST', path: '/v1/voice/sessions', auth: 'member', status: 201, handler(context) {
      const body = parse(start, context.body);
      const user = principal(context.user);
      if (user.kind !== 'user') fail('forbidden', 'Only a user can start voice.');
      service.sweep();
      const conversation = services.auth.conversation(user, body.conversationId);
      if (!['dm', 'task', 'team_dm'].includes(conversation.kind) || conversation.ownerUserId !== user.userId || conversation.botIds.length !== 1) fail('forbidden', 'Voice requires your own private conversation.');
      const bot = services.auth.bot(user, conversation.botIds[0]!);
      if (bot.visibility === 'team' && bot.ownerUserId !== user.userId) fail('forbidden', 'Voice is unavailable for a teammate’s Team Bot.');
      const device = services.store.require<P.Device>('devices', body.deviceId);
      if (device.userId !== user.userId || (user.deviceId !== null && user.deviceId !== device.id)) fail('forbidden', 'Use your own current device.');
      return services.store.transaction(() => {
        const active = services.store.list<P.VoiceSession>('voiceSessions', s => s.userId === user.userId && s.state === 'active')[0];
        if (active) fail('conflict', 'End the existing voice session first.', true, { voiceSessionId: active.id });
        const session: P.VoiceSession = services.resource('voice', { conversationId: conversation.id, userId: user.userId, deviceId: device.id, settings: body.settings ?? bot.voice, state: 'active' as const, startedAtMs: services.now(), endedAtMs: null, durationMs: 0, transcriptEntryIds: [], muted: false, feedback: null });
        services.store.put('voiceSessions', session);
        services.store.setMetadata(`voicePrincipal:${session.id}`, user);
        if (!actions.connections.has(`${user.userId}:${device.id}`)) services.store.setMetadata(`voiceDisconnect:${session.id}`, services.now() + GRACE_MS);
        context.nonceResourceIds.push(session.id);
        actions.emit(session);
        return session;
      });
    } },
    { method: 'GET', path: '/v1/voice/sessions/:id', auth: 'member', body: 'none', status: 200, handler(context) { service.sweep(); return actions.own(principal(context.user), context.params.id!); } },
    { method: 'PATCH', path: '/v1/voice/sessions/:id', auth: 'member', status: 200, handler(context) {
      const body = parse(patch, context.body);
      service.sweep();
      const session = actions.own(principal(context.user), context.params.id!);
      services.mutations.checkRevision(session, body.revision);
      if (session.state !== 'active' && (body.muted !== undefined || body.settings !== undefined)) fail('conflict', 'Ended voice settings cannot change.');
      const changes: Partial<P.VoiceSession> = {};
      if (body.muted !== undefined) changes.muted = body.muted;
      if (body.settings !== undefined) changes.settings = body.settings;
      if (body.feedback !== undefined) changes.feedback = body.feedback;
      const changed = services.update(session, changes);
      services.store.transaction(() => { services.store.put('voiceSessions', changed); actions.syncSummary(changed); actions.emit(changed); });
      return changed;
    } },
    { method: 'POST', path: '/v1/voice/sessions/:id/end', auth: 'member', status: 200, handler(context) {
      parse(mutation, context.body);
      service.sweep();
      const user = principal(context.user);
      return actions.finish(actions.own(user, context.params.id!), 'ended', user);
    } },
  ];
}
