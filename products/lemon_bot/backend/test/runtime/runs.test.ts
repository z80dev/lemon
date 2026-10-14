import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { ApiError } from '../../src/core/errors';
import { buildMemoryContextKey, buildPrivateBotMemoryContextKey, createRuntimeService, observeInvocation, quiesceBotInvocations, reserveCronAdmission, revokeConnectorInvocations, type InvocationContext, type InvocationProofBinding, type RuntimeMapping } from '../../src/runtime/runs';
import { fixture, productExecutionProjection } from './fixture';

describe('owned placed runtime', () => {
  test('legacy sharing, manager labels and administrative roles cannot execute another owner’s Bot before any RPC', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const legacy = { ...f.bot, visibility: 'team', published: true, managerUserIds: [f.bob.userId] }; f.store.put('bots', legacy);
    f.services.auth.bot = (_actor, botId) => f.store.require<P.Bot>('bots', botId);
    f.services.auth.conversation = (_actor, conversationId) => f.store.require<P.Conversation>('conversations', conversationId);
    try {
      for (const role of ['member', 'admin', 'owner'] as const) {
        const foreign = { ...f.bob, role };
        await expect(runtime.submit(foreign, f.conversation, legacy, { clientNonce: `foreign_owner_nonce_${role}`, text: 'work' })).rejects.toMatchObject({ code: 'forbidden' });
        expect(() => buildPrivateBotMemoryContextKey(f.services, foreign, legacy)).toThrow(ApiError);
      }
      expect(f.calls).toHaveLength(0);
      expect(f.store.list('runs')).toHaveLength(0);
    } finally { runtime.close(); f.store.close(); }
  });

  test('a retained genuine invocation proof cannot authorize a Bot owned by another human', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const started = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'legacy_foreign_proof_001', text: 'work' });
      const proof = String(f.calls.find(call => call.method === 'node.secrets.set')!.params.value);
      const before = f.calls.length;
      f.store.put('bots', { ...f.bot, ownerUserId: f.bob.userId, visibility: 'team', published: true, managerUserIds: [f.alice.userId] });
      f.services.auth.bot = (_actor, botId) => f.store.require<P.Bot>('bots', botId);
      expect(() => observeInvocation(f.services, proof)).toThrow(ApiError);
      expect(f.calls).toHaveLength(before);
      expect(f.store.metadata(`runPrincipal:${started.run.id}`)).toEqual(f.alice);
      expect(f.store.require<P.Run>('runs', started.run.id).initiatorUserId).toBe(f.alice.userId);
    } finally { runtime.close(); f.store.close(); }
  });

  test('incomplete, duplicate or unowned MCP projection never provisions credentials or dispatches chat', async () => {
    const reply = productExecutionProjection();
    const invalid = [
      { ...reply, count: 0 },
      { ...reply, tools: reply.tools.slice(1) },
      { ...reply, tools: [reply.tools[0]!, ...reply.tools.slice(0, -1)] },
      { ...reply, tools: reply.tools.map((tool, index) => index === 0 ? { ...tool, name: 'not_a_product_tool' } : tool) },
    ];
    for (const projection of invalid) {
      const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime; const original = f.rpc;
      f.rpc = async (method, params) => method === 'mcp.execution_names' ? projection : original(method, params);
      try {
        await expect(runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'invalid_projection_nonce1', text: 'work' })).rejects.toMatchObject({ code: 'upstream_unavailable' });
        expect(f.calls.filter(call => call.method === 'mcp.execution_names')).toHaveLength(1);
        expect(f.calls.filter(call => ['node.secrets.set', 'chat.send'].includes(call.method))).toHaveLength(0);
        const failed = f.store.list<P.Run>('runs')[0]!;
        expect(failed.status).toBe('failed');
        expect(f.store.metadata(`invocationProofState:${failed.id}`)).toBeNull();
      } finally { runtime.close(); f.store.close(); }
    }
  });

  test('missing pure execution-name support fails closed before provisioning or chat dispatch', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    f.services.lemon.methods = f.services.lemon.methods.filter(method => method !== 'mcp.execution_names');
    try {
      await expect(runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'missing_projection_nonce01', text: 'work' })).rejects.toMatchObject({ code: 'capability_unavailable', retrySafe: true });
      expect(f.calls.filter(call => ['mcp.execution_names', 'node.secrets.set', 'chat.send'].includes(call.method))).toHaveLength(0);
      expect(f.store.list<P.Run>('runs')).toMatchObject([{ status: 'failed' }]);
    } finally { runtime.close(); f.store.close(); }
  });

  test('measured implementation support does not grant files or shell to an unconfigured Bot', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const started = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'measured_not_granted_001', text: 'work' });
      const context = f.store.metadata<InvocationContext>(`runtimeInvocation:${started.run.id}`)!;
      expect(context.invocationToolPolicy).toMatchObject({ profile: 'custom', deny: expect.arrayContaining(['read', 'write', 'bash', 'lsp_diagnostics', 'remember', 'recall']) });
      expect(context.invocationToolPolicy.allow).not.toEqual(expect.arrayContaining(['read', 'write', 'bash']));
      expect(f.store.list<P.BotGrant>('botGrants').every(grant => grant.requestedLevel === 'off')).toBe(true);
      const projection = f.calls.find(call => call.method === 'mcp.execution_names')!;
      expect(projection.mutation).toBe(false);
      expect(Object.keys(projection.params).sort()).toEqual(['server', 'toolNames']);
      expect(projection.params.server).toEqual({ name: 'lemon-bot', url: 'https://product.example/mcp' });
    } finally { runtime.close(); f.store.close(); }
  });

  test('another native execution cannot supply completion or terminal cancellation proof', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const started = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'foreign_completion_nonce1', text: 'work' });
      const sessionKey = f.store.metadata<RuntimeMapping>(`runtimeRun:${started.run.id}`)!.sessionKey;
      const original = f.rpc;
      f.rpc = async (method, params) => {
        if (method === 'chat.abort') { expect(params).toEqual({ runId: started.run.id, sessionKey }); return { aborted: true }; }
        if (method === 'agent.wait') { expect(params.runId).toBe(started.run.id); return { runId: 'foreign_native_run', ok: false, cancelled: true, answer: null }; }
        return original(method, params);
      };
      await runtime.project('agent', { type: 'completed', runId: started.run.id, sessionKey, ok: false, cancelled: true });
      expect(f.store.require<P.Run>('runs', started.run.id).status).toBe('running');
      expect(f.store.metadata(`runtimeReconciliation:${started.run.id}`)).toMatchObject({ pending: true, code: 'upstream_unavailable' });
      expect(await quiesceBotInvocations(f.services, f.alice, f.bot.id, { principalOnly: true })).toMatchObject({ status: 'outcome_unknown', runIds: [started.run.id] });
      expect(f.store.require<P.Run>('runs', started.run.id).status).toBe('running');
      expect(f.store.metadata(`runtimeTerminalProjectionPending:${started.run.id}`)).toBeNull();
      expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(1);
    } finally { runtime.close(); f.store.close(); }
  });

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


  test('private native memory identity does not require a surviving main conversation', () => {
    const f = fixture();
    try {
      const key = buildMemoryContextKey(f.services, f.alice, f.conversation, f.bot);
      f.store.remove('conversations', f.conversation.id);
      expect(buildPrivateBotMemoryContextKey(f.services, f.alice, f.bot)).toBe(key);
    } finally { f.store.close(); }
  });

  test('owner group-return specialist execution retains the original owner and authorized response room', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const task: P.Conversation = { ...f.conversation, id: 'specialist_private_task', kind: 'task' }; f.store.put('conversations', task);
    const helper: P.Bot = { ...f.bot, id: 'owned_return_helper', profileId: 'lb-return-helper', mainConversationId: '' }; f.store.put('bots', helper);
    const group: P.Conversation = { ...f.conversation, id: 'owned_return_group', kind: 'group', botIds: [f.bot.id, helper.id] }; f.store.put('conversations', group);
    const nonce = 'shared_return_nonce_0001';
    f.store.setMetadata(`submissionContext:${f.alice.kind}:${f.alice.id}:${task.id}:${nonce}`, { returnConversationId: group.id });
    const audiences: unknown[] = []; f.services.integrations.connectorConfig = async (_actor, _botId, conversationId, operationId) => { audiences.push(conversationId); if (operationId) f.store.setMetadata(`invocationConnectors:${operationId}`, []); return []; };
    try {
      const result = await runtime.submit(f.alice, task, f.bot, { clientNonce: nonce, text: 'specialist work' });
      expect(audiences).toEqual([group.id]);
      const context = f.store.metadata<InvocationContext>(`runtimeInvocation:${result.run.id}`)!;
      expect(context.memoryContextKey).toBe(buildMemoryContextKey(f.services, f.alice, group, f.bot));
      expect(context.memoryContextKey).toBe(buildPrivateBotMemoryContextKey(f.services, f.alice, f.bot));
      expect(f.store.metadata(`runPrincipal:${result.run.id}`)).toEqual(f.alice);
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

  test('owner profile memory authority remains stable across epochs and owner group rooms', () => {
    const f = fixture();
    try {
      const privateKey = buildMemoryContextKey(f.services, f.alice, f.conversation, f.bot);
      f.store.setMetadata(`botPlacementEpoch:${f.bot.id}`, 2); f.store.setMetadata(`connectorEpoch:connector_fixture`, 9);
      expect(buildMemoryContextKey(f.services, f.alice, f.conversation, f.bot)).toBe(privateKey);
      const helper: P.Bot = { ...f.bot, id: 'owned_memory_helper', profileId: 'lb-memory-helper', mainConversationId: '' }; f.store.put('bots', helper);
      const shared: P.Conversation = { ...f.conversation, id: 'owned_memory_group', kind: 'group', botIds: [f.bot.id, helper.id] }; f.store.put('conversations', shared);
      const sharedKey = buildMemoryContextKey(f.services, f.alice, shared, f.bot);
      expect(sharedKey).toBe(privateKey);
      expect(() => buildMemoryContextKey(f.services, f.bob, shared, f.bot)).toThrow(ApiError);
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
      expect(f.store.metadata<RuntimeMapping>(`runtimeRun:${runId}`)).toMatchObject({ upstreamRunId: runId, sessionKey: `agent:${f.bot.profileId}:main`, nodeId: 'node_1', dispatched: true });
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
      f.rpc = async (method, params) => { if (method === 'agent.wait') return { runId: params.runId, ok: true, answer: 'authoritative complete answer, not the truncated event preview', cancelled: false }; throw new Error(`Unexpected ${method}`); };
      await runtime.project('agent', { type: 'completed', runId: result.run.id, sessionKey, ok: true, answer: 'truncated' });
      expect(f.store.require<P.Run>('runs', result.run.id).status).toBe('succeeded');
      expect(f.store.list<P.TranscriptEntry>('entries').filter(entry => entry.kind === 'message')).toMatchObject([{ text: 'authoritative complete answer, not the truncated event preview', streaming: false }]);
    } finally { runtime.close(); f.store.close(); }
  });
  test('initiator, connector operation and profile memory identity remain the actual Bot owner’s authority', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const ownedConversation: P.Conversation = { ...f.conversation, id: 'owner_private_conversation', kind: 'task' }; f.store.put('conversations', ownedConversation);
    const configs: unknown[] = [];
    f.services.integrations.connectorConfig = async (actor, botId, conversationId, operationId) => { configs.push({ actor, botId, conversationId, operationId }); if (operationId) f.store.setMetadata(`invocationConnectors:${operationId}`, []); return []; };
    try {
      const result = await runtime.submit(f.alice, ownedConversation, f.bot, { clientNonce: 'owner_context_nonce_0001', text: 'work' });
      expect(configs).toEqual([{ actor: f.alice, botId: f.bot.id, conversationId: ownedConversation.id, operationId: result.run.id }]);
      const send = f.calls.find(call => call.method === 'chat.send')!;
      expect(f.store.metadata<InvocationContext>(`runtimeInvocation:${result.run.id}`)!.memoryContextKey).toBe(buildPrivateBotMemoryContextKey(f.services, f.alice, f.bot));
      expect(send.params.sessionKey).toBe(`agent:${f.bot.profileId}:task-${ownedConversation.id}`);
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
      const sessionKey = f.store.metadata<RuntimeMapping>(`runtimeRun:${result.run.id}`)!.sessionKey;
      const proof = String(f.calls.find(call => call.method === 'node.secrets.set')!.params.value);
      f.rpc = async (method, params) => {
        if (method === 'chat.abort') { expect(params).toEqual({ runId: result.run.id, sessionKey }); return { aborted: true, summary: { dispatchStatus: 'sent' } }; }
        if (method === 'agent.wait') { expect(params).toEqual({ runId: result.run.id, timeoutMs: 1 }); throw new ApiError('upstream_unavailable', 'Not terminal yet.'); }
        throw new Error(`Unexpected ${method}`);
      };
      expect((await runtime.cancel(f.alice, result.run.id)).status).toBe('running');
      expect(() => observeInvocation(f.services, proof)).toThrow(ApiError);
      f.rpc = async (method, params) => {
        if (method === 'chat.abort') { expect(params).toEqual({ runId: result.run.id, sessionKey }); return { aborted: true, summary: { dispatchStatus: 'sent' } }; }
        if (method === 'agent.wait') { expect(params).toEqual({ runId: result.run.id, timeoutMs: 1 }); return { runId: result.run.id, ok: false, answer: null, cancelled: true }; }
        throw new Error(`Unexpected ${method}`);
      };
      expect((await runtime.cancel(f.alice, result.run.id)).status).toBe('cancelled');
    } finally { runtime.close(); f.store.close(); }
  });
  test('scheduled owner admission reserves once under fixed native IDs, and principal-only quiescence leaves a legacy foreign run fenced from new execution', async () => {
    const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const routine: P.Routine & { conversationId: string } = f.services.resource('routine', { botId: f.bot.id, ownerUserId: f.alice.userId, name: 'Schedule', instruction: 'work', trigger: { kind: 'schedule', cron: '0 * * * *', timezone: 'UTC' }, enabled: true, nextRunAtMs: null, scheduleDescription: '', lastRunId: null, webhookUrl: null, cronJobId: 'fixed_job', conversationId: f.conversation.id }); f.store.put('routines', routine);
      const context = { cronRunId: 'fixed_cron_run', routerRunId: 'fixed_native_run', jobId: 'fixed_job', profileId: f.bot.profileId, creatorId: 'alice', workspaceId: 'workspace', routineId: routine.id, triggeredBy: 'schedule', scheduledForMs: null };
      await reserveCronAdmission(f.services, f.alice, routine.id, context); await reserveCronAdmission(f.services, f.alice, routine.id, context);
      expect(f.store.list('runs')).toHaveLength(1); expect(f.store.list('routineRuns')).toHaveLength(1); expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(0);
      const reserved = f.store.list<P.Run>('runs')[0]!;
      expect(f.store.metadata(`runCron:${reserved.id}`)).toBe(context.cronRunId);
      const bobRun: P.Run = f.services.resource('run', { conversationId: f.conversation.id, botId: f.bot.id, initiatorUserId: 'bob', clientNonce: 'bob_run_nonce_0000000', status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null }); f.store.put('runs', bobRun);
      f.rpc = async (method, params) => {
        if (method === 'chat.abort') { expect(params.runId).toBe(context.routerRunId); return { aborted: true }; }
        if (method === 'agent.wait') { expect(params).toEqual({ runId: context.routerRunId, timeoutMs: 1_000, includeAnswer: false }); return { runId: context.routerRunId, ok: false, answer: null, cancelled: true }; }
        throw new Error(`Unexpected ${method}`);
      };
      const stopped = await quiesceBotInvocations(f.services, f.alice, f.bot.id, { principalOnly: true });
      expect(stopped.status).toBe('cancelled'); expect(stopped.runIds).not.toContain(bobRun.id); expect(f.store.require<P.Run>('runs', bobRun.id).status).toBe('running');
    } finally { runtime.close(); f.store.close(); }
  });
});
