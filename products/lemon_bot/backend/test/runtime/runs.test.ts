import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { ApiError } from '../../src/core/errors';
import { buildMemoryContextKey, buildPrivateBotMemoryContextKey, createRuntimeService, observeInvocation, quiesceBotInvocations, reserveCronAdmission, revokeConnectorInvocations, type InvocationContext, type InvocationProofBinding, type RuntimeMapping } from '../../src/runtime/runs';
import { fixture } from './fixture';

describe('owned placed runtime', () => {
  test('revocation reads only terminal status; the actual initiating context separately owns full completion projection', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const started = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'status_only_stop_nonce01', text: 'work' });
      const sessionKey = f.store.metadata<RuntimeMapping>(`runtimeRun:${started.run.id}`)!.sessionKey;
      await runtime.project('chat', { type: 'delta', runId: started.run.id, sessionKey, seq: 1, text: 'partial private answer' });
      const original = f.rpc;
      f.rpc = async (method, params) => {
        if (method === 'chat.abort') return { aborted: true };
        if (method === 'agent.wait') { expect(params.includeAnswer).toBe(false); return { runId: started.run.id, ok: false, cancelled: true, answer: null }; }
        return original(method, params);
      };
      const stopped = await quiesceBotInvocations(f.services, f.alice, f.bot.id, { principalOnly: true });
      expect(stopped.status).toBe('cancelled');
      expect(f.store.metadata(`runtimeTerminalProjectionPending:${started.run.id}`)).toBe(true);
      expect(f.store.list<P.TranscriptEntry>('entries').filter(entry => entry.kind === 'message')).toMatchObject([{ text: 'partial private answer', streaming: false }]);
      f.rpc = async (method, params) => {
        if (method === 'agent.wait') { expect(params.includeAnswer).toBeUndefined(); return { runId: started.run.id, ok: false, cancelled: true, answer: 'authoritative private completion' }; }
        return original(method, params);
      };
      await runtime.project('agent', { type: 'completed', runId: started.run.id, sessionKey, ok: false, cancelled: true });
      expect(f.store.metadata(`runtimeTerminalProjectionPending:${started.run.id}`)).toBe(false);
      expect(f.store.list<P.TranscriptEntry>('entries').filter(entry => entry.kind === 'message')).toMatchObject([{ text: 'authoritative private completion', streaming: false }]);
    } finally { runtime.close(); f.store.close(); }
  });

  test('a shared credential owner can revoke after losing Bot management, while another member cannot', async () => {
    const f = fixture();
    const connector: P.Connector = f.services.resource('connector', { botId: f.bot.id, ownerUserId: f.alice.userId, name: 'Shared account', url: 'https://connector.example/mcp', accountLabel: 'Owner account', authKind: 'oauth' as const, state: 'connected' as const, tools: [], secretHeaderNames: [], shared: true, lastError: null });
    f.store.put('connectors', connector); f.services.auth.bot = () => { throw new ApiError('forbidden', 'Management removed.'); };
    try {
      expect(await revokeConnectorInvocations(f.services, f.alice, f.bot.id, connector.id)).toEqual({ runIds: [], status: 'cancelled' });
      await expect(revokeConnectorInvocations(f.services, f.bob, f.bot.id, connector.id)).rejects.toMatchObject({ code: 'forbidden' });
      expect(f.calls).toHaveLength(0);
    } finally { f.store.close(); }
  });

  test('private native memory identity does not require a surviving main conversation', () => {
    const f = fixture();
    try {
      const key = buildMemoryContextKey(f.services, f.alice, f.conversation, f.bot);
      f.store.remove('conversations', f.conversation.id);
      expect(buildPrivateBotMemoryContextKey(f.services, f.alice, f.bot)).toBe(key);
    } finally { f.store.close(); }
  });

  test('shared-return specialist execution cannot inherit private notes or a private memory realm', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const task: P.Conversation = { ...f.conversation, id: 'specialist_private_task', kind: 'task' }; f.store.put('conversations', task);
    const group: P.Conversation = { ...f.conversation, kind: 'group', humanUserIds: [f.alice.userId, f.bob.userId] }; f.store.put('conversations', group);
    f.store.put('memories', f.services.resource('memory', { botId: f.bot.id, scope: 'private_note', userId: f.alice.userId, text: 'private target fact', kind: 'fact', sourceEntryId: null }));
    const nonce = 'shared_return_nonce_0001';
    f.store.setMetadata(`submissionContext:${f.alice.kind}:${f.alice.id}:${task.id}:${nonce}`, { returnConversationId: group.id });
    const audiences: unknown[] = []; f.services.integrations.connectorConfig = async (_actor, _botId, conversationId, operationId) => { audiences.push(conversationId); if (operationId) f.store.setMetadata(`invocationConnectors:${operationId}`, []); return []; };
    try {
      const result = await runtime.submit(f.alice, task, f.bot, { clientNonce: nonce, text: 'specialist work' });
      expect(audiences).toEqual([group.id]);
      const context = f.store.metadata<InvocationContext>(`runtimeInvocation:${result.run.id}`)!;
      expect(context.memoryContextKey).toBe(buildMemoryContextKey(f.services, f.alice, group, f.bot));
      expect(context.memoryContextKey).not.toBe(buildPrivateBotMemoryContextKey(f.services, f.alice, f.bot));
      expect(String(f.calls.find(call => call.method === 'chat.send')!.params.prompt)).not.toContain('private target fact');
    } finally { runtime.close(); f.store.close(); }
  });

  test('real bound MCP tool observation admits gates before the chat acknowledgment without trusting a body run ID', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime; const original = f.rpc;
    f.rpc = async (method, params) => {
      if (method === 'chat.send') {
        const proof = String(f.calls.find(call => call.method === 'node.secrets.set')!.params.value);
        expect(f.store.require<P.Run>('runs', String(params.runId)).status).toBe('reserved');
        expect(observeInvocation(f.services, proof)).toMatchObject({ id: params.runId, status: 'running' });
        expect(() => observeInvocation(f.services, 'model_supplied_body_run_id')).toThrow();
      }
      return original(method, params);
    };
    try {
      const result = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'early_proof_nonce_0001', text: 'work' });
      expect(result.run.status).toBe('running');
      f.store.setMetadata(`connectorRevocation:${f.bot.id}`, { status: 'pending' });
      const proof = String(f.calls.find(call => call.method === 'node.secrets.set')!.params.value);
      expect(() => observeInvocation(f.services, proof)).toThrow();
    } finally { runtime.close(); f.store.close(); }
  });

  test('uncertain credential provisioning cannot replay or dispatch native execution', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime; const original = f.rpc;
    f.rpc = async (method, params) => {
      if (method === 'node.secrets.set') throw new ApiError('outcome_unknown', 'Receipt unavailable.', false);
      return original(method, params);
    };
    try {
      const message = { clientNonce: 'uncertain_proof_nonce_01', text: 'work' };
      const first = await runtime.submit(f.alice, f.conversation, f.bot, message);
      expect(first.run.status).toBe('outcome_unknown');
      const replay = await runtime.submit(f.alice, f.conversation, f.bot, message);
      expect(replay.run.id).toBe(first.run.id);
      expect(f.calls.filter(call => call.method === 'node.secrets.set')).toHaveLength(1);
      expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(0);
    } finally { runtime.close(); f.store.close(); }
  });

  test('memory authority remains stable across epochs but is isolated from shared audience context', () => {
    const f = fixture();
    try {
      const privateKey = buildMemoryContextKey(f.services, f.alice, f.conversation, f.bot);
      f.store.setMetadata(`botPlacementEpoch:${f.bot.id}`, 2); f.store.setMetadata(`connectorEpoch:connector_fixture`, 9);
      expect(buildMemoryContextKey(f.services, f.alice, f.conversation, f.bot)).toBe(privateKey);
      const shared = { ...f.conversation, kind: 'group' as const, humanUserIds: [f.alice.userId, f.bob.userId] }; f.store.put('conversations', shared);
      const sharedKey = buildMemoryContextKey(f.services, f.alice, shared, f.bot);
      expect(sharedKey).not.toBe(privateKey);
      expect(buildMemoryContextKey(f.services, f.bob, shared, f.bot)).not.toBe(sharedKey);
    } finally { f.store.close(); }
  });

  test('core MCP proof is provisioned on the actual node and bound to its fixed initiating run', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const result = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'bound_invocation_nonce_01', text: 'work' });
      const write = f.calls.find(call => call.method === 'node.secrets.set'); expect(write).toBeDefined();
      expect(write!.params).toMatchObject({ nodeId: f.machine.nodeId, name: `lemon_bot/invocations/${result.run.id}`, operationId: result.run.id });
      const proof = String(write!.params.value);
      expect(f.store.metadata<InvocationProofBinding>(`invocationProof:${f.services.mutations.digest(proof)}`)).toMatchObject({ runId: result.run.id, nativeRunId: result.run.id, botId: f.bot.id, principal: { id: f.alice.id, userId: f.alice.userId } });
      const context = f.store.metadata<InvocationContext>(`runtimeInvocation:${result.run.id}`);
      expect(context!.invocationMcpServers[0]!.headers['X-Lemon-Bot-Invocation']).toBe(`\${LEMON_SECRET:lemon_bot/invocations/${result.run.id}}`);
      expect(JSON.stringify(context)).not.toContain(proof);
    } finally { runtime.close(); f.store.close(); }
  });

  test('reserves fixed upstream/session/principal mappings before dispatch and never replays an uncertain submission', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const original = f.rpc;
    f.rpc = async (method, params) => {
      if (method !== 'chat.send') return original(method, params);
      const runId = String(params.runId);
      expect(f.store.require<P.Run>('runs', runId).status).toBe('reserved');
      expect(f.store.metadata<RuntimeMapping>(`runtimeRun:${runId}`)).toMatchObject({ upstreamRunId: runId, sessionKey: `agent:${f.bot.profileId}:dm-alice`, nodeId: 'node_1', dispatched: true });
      expect(f.store.metadata(`runPrincipal:${runId}`)).toEqual(f.alice);
      throw new ApiError('outcome_unknown', 'Dispatched but no reply.', false, { resourceIds: [runId] });
    };
    try {
      const message = { clientNonce: 'fixed_submission_nonce_01', text: 'work' };
      const first = await runtime.submit(f.alice, f.conversation, f.bot, message);
      expect(first.run.status).toBe('outcome_unknown'); expect(first.delivery.effectiveMode).toBe('outcome_unknown');
      const replay = await runtime.submit(f.alice, f.conversation, f.bot, message);
      expect(replay.run.id).toBe(first.run.id); expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(1);
      await expect(runtime.submit(f.alice, f.conversation, f.bot, { ...message, text: 'different intent' })).rejects.toMatchObject({ code: 'nonce_conflict' });
    } finally { runtime.close(); f.store.close(); }
  });
  test('global remote fanout cannot project an unowned run or a mismatched session; UTF16 deltas close only with authoritative full completion', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const result = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'remote_projection_nonce_1', text: 'work' });
      const sessionKey = runtime.sessionKey(f.conversation, f.bot);
      await runtime.project('chat', { type: 'delta', runId: 'foreign_swarm_run', sessionKey, seq: 1, text: 'must not leak' });
      await runtime.project('chat', { type: 'delta', runId: result.run.id, sessionKey: 'wrong_session', seq: 1, text: 'must not leak' });
      expect(f.store.list('entries')).toHaveLength(0);
      await runtime.project('chat', { type: 'delta', runId: result.run.id, sessionKey, seq: 1, text: '🙂' });
      await runtime.project('chat', { type: 'delta', runId: result.run.id, sessionKey, seq: 2, text: ' answer' });
      const deltaEvents = f.services.events.replay(f.alice, '0').filter(event => event.event === 'entry.delta');
      expect(deltaEvents.map(event => event.event === 'entry.delta' ? event.payload.offset : -1)).toEqual([0, 2]);
      expect(f.services.events.replay(f.bob, '0').some(event => event.event === 'entry.delta')).toBe(false);
      expect(f.services.events.replay(f.bob, '0').filter(event => event.event === 'bot.upserted').every(event => event.event !== 'bot.upserted' || event.payload.activeRunIds.length === 0)).toBe(true);
      f.rpc = async method => { if (method === 'agent.wait') return { ok: true, answer: 'authoritative complete answer, not the truncated event preview', cancelled: false }; throw new Error(`Unexpected ${method}`); };
      await runtime.project('agent', { type: 'completed', runId: result.run.id, sessionKey, ok: true, answer: 'truncated' });
      expect(f.store.require<P.Run>('runs', result.run.id).status).toBe('succeeded');
      expect(f.store.list<P.TranscriptEntry>('entries').filter(entry => entry.kind === 'message')).toMatchObject([{ text: 'authoritative complete answer, not the truncated event preview', streaming: false }]);
    } finally { runtime.close(); f.store.close(); }
  });
  test('initiator, connector consent operation and private notes stay scoped to the collaborator rather than Team owner', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const bobConversation: P.Conversation = { ...f.conversation, id: 'bob_private_conversation', ownerUserId: f.bob.userId, humanUserIds: [f.bob.userId] }; f.store.put('conversations', bobConversation);
    f.store.put('memories', f.services.resource('memory', { botId: f.bot.id, scope: 'private_note', userId: 'alice', text: 'owner private fact', kind: 'fact', sourceEntryId: null }));
    f.store.put('memories', f.services.resource('memory', { botId: f.bot.id, scope: 'private_note', userId: 'bob', text: 'collaborator private fact', kind: 'fact', sourceEntryId: null }));
    const configs: unknown[] = [];
    f.services.integrations.connectorConfig = async (actor, botId, conversationId, operationId) => { configs.push({ actor, botId, conversationId, operationId }); if (operationId) f.store.setMetadata(`invocationConnectors:${operationId}`, []); return []; };
    try {
      const result = await runtime.submit(f.bob, bobConversation, f.bot, { clientNonce: 'collaborator_nonce_0001', text: 'work' });
      expect(configs).toEqual([{ actor: f.bob, botId: f.bot.id, conversationId: bobConversation.id, operationId: result.run.id }]);
      const send = f.calls.find(call => call.method === 'chat.send')!;
      expect(String(send.params.prompt)).toContain('collaborator private fact'); expect(String(send.params.prompt)).not.toContain('owner private fact');
      expect(send.params.sessionKey).toBe(`agent:${f.bot.profileId}:dm-bob`);
      expect(send.params.invocationMcpServers).toMatchObject([{ name: 'lemon-bot', headers: { Authorization: 'Bearer ${LEMON_SECRET:LEMON_BOT_FIXTURE}' } }]);
    } finally { runtime.close(); f.store.close(); }
  });
  test('steer follows the acknowledged target while interrupt keeps a new replacement execution ID', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const first = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'control_original_nonce_1', text: 'first' });
      const original = f.rpc;
      f.rpc = async (method, params) => { if (method === 'chat.send') return { runId: params.runId, sessionKey: params.sessionKey, effectiveMode: params.queueMode === 'steer' ? 'steer' : 'interrupt', targetRunId: first.run.id }; return original(method, params); };
      const steered = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'control_steering_nonce_1', text: 'change direction', mode: 'steer' });
      expect(steered.delivery).toMatchObject({ effectiveMode: 'steering', targetRunId: first.run.id });
      expect(f.store.metadata<RuntimeMapping>(`runtimeRun:${steered.run.id}`)?.executionRunId).toBe(first.run.id);
      const interrupted = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'control_interrupt_nonce', text: 'replace', mode: 'interrupt' });
      expect(interrupted.delivery).toMatchObject({ effectiveMode: 'interrupting', targetRunId: first.run.id });
      expect(f.store.metadata<RuntimeMapping>(`runtimeRun:${interrupted.run.id}`)?.executionRunId).toBe(interrupted.run.id);
    } finally { runtime.close(); f.store.close(); }
  });
  test('cancel destination acknowledgment alone is not a cancelled run', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const result = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'cancellation_nonce_001', text: 'work' });
      f.rpc = async method => { if (method === 'chat.abort') return { aborted: true, summary: { dispatchStatus: 'sent' } }; if (method === 'agent.wait') throw new ApiError('upstream_unavailable', 'Not terminal yet.'); throw new Error(`Unexpected ${method}`); };
      expect((await runtime.cancel(f.alice, result.run.id)).status).toBe('running');
      f.rpc = async method => method === 'chat.abort' ? { aborted: true, summary: { dispatchStatus: 'sent' } } : { ok: false, answer: null, cancelled: true };
      expect((await runtime.cancel(f.alice, result.run.id)).status).toBe('cancelled');
    } finally { runtime.close(); f.store.close(); }
  });
  test('scheduled admission reserves once under fixed native IDs, and principal-only policy quiescence never stops another collaborator', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const routine: P.Routine & { conversationId: string } = f.services.resource('routine', { botId: f.bot.id, ownerUserId: f.alice.userId, name: 'Schedule', instruction: 'work', trigger: { kind: 'schedule', cron: '0 * * * *', timezone: 'UTC' }, enabled: true, nextRunAtMs: null, scheduleDescription: '', lastRunId: null, webhookUrl: null, cronJobId: 'fixed_job', conversationId: f.conversation.id }); f.store.put('routines', routine);
      const context = { cronRunId: 'fixed_cron_run', routerRunId: 'fixed_native_run', jobId: 'fixed_job', profileId: f.bot.profileId, creatorId: 'alice', workspaceId: 'workspace', routineId: routine.id, triggeredBy: 'schedule', scheduledForMs: null };
      await reserveCronAdmission(f.services, f.alice, routine.id, context); await reserveCronAdmission(f.services, f.alice, routine.id, context);
      expect(f.store.list('runs')).toHaveLength(1); expect(f.store.list('routineRuns')).toHaveLength(1); expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(0);
      const reserved = f.store.list<P.Run>('runs')[0]!;
      expect(f.store.metadata(`runCron:${reserved.id}`)).toBe(context.cronRunId);
      const bobRun: P.Run = f.services.resource('run', { conversationId: f.conversation.id, botId: f.bot.id, initiatorUserId: 'bob', clientNonce: 'bob_run_nonce_0000000', status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null }); f.store.put('runs', bobRun);
      f.rpc = async method => method === 'chat.abort' ? { aborted: true } : { ok: false, answer: null, cancelled: true };
      const stopped = await quiesceBotInvocations(f.services, f.alice, f.bot.id, { principalOnly: true });
      expect(stopped.status).toBe('cancelled'); expect(stopped.runIds).not.toContain(bobRun.id); expect(f.store.require<P.Run>('runs', bobRun.id).status).toBe('running');
    } finally { runtime.close(); f.store.close(); }
  });
});
