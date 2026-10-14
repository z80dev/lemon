import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { ApiError } from '../../src/core/errors';
import { configureNativeFollowupAdmission, createRuntimeAdmissionRoutes, nativeFollowupAdmissionPath, type NativeFollowupLineage } from '../../src/runtime/admission';
import { createRuntimeService, observeInvocation, type InvocationContext, type RuntimeMapping } from '../../src/runtime/runs';
import { fixture } from './fixture';

async function setup() {
  const f = fixture(); const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
  f.services.lemon.methods.push('profile.followup.admission.set', 'runs.followup.lineage.get');
  const original = f.rpc; let token = ''; let lineage: NativeFollowupLineage | null = null;
  f.rpc = async (method, params) => {
    if (method === 'profile.followup.admission.set') { expect(Object.keys(params).sort()).toEqual(['profileId', 'token', 'url']); expect(params.profileId).toBe(f.bot.profileId); token = String(params.token); expect(params.url).toBe('https://product.example' + nativeFollowupAdmissionPath); return { profileId: params.profileId, configured: true }; }
    if (method === 'runs.followup.lineage.get') { expect(Object.keys(params)).toEqual(['runId']); if (!lineage || params.runId !== lineage.runId) throw new ApiError('not_found', 'No actual native reservation.'); return lineage; }
    return original(method, params);
  };
  await configureNativeFollowupAdmission(f.services, f.bot);
  const started = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'native_source_nonce_0001', text: 'work' });
  const source = f.store.metadata<InvocationContext>(`runtimeInvocation:${started.run.id}`)!;
  const mapped = f.store.metadata<RuntimeMapping>(`runtimeRun:${started.run.id}`)!;
  lineage = { runId: 'native_F_fixed_001', sourceRootRunId: started.run.id, parentRunId: started.run.id, sourceProfileId: f.bot.profileId, sourceSessionKey: mapped.sessionKey, sourceInvocationContextKey: source.invocationContextKey, sourceMemoryContextKey: source.memoryContextKey, targetProfileId: f.bot.profileId, targetAgentId: f.bot.profileId, targetSessionKey: mapped.sessionKey, targetNodeId: 'node_1', sourceRestrictiveToolPolicy: source.invocationToolPolicy };
  const route = createRuntimeAdmissionRoutes(f.services)[0]!;
  function context(body: unknown = { runId: lineage!.runId }, bearer = token) { const value = f.context(route, body); value.request = new Request('https://product.example' + nativeFollowupAdmissionPath, { method: 'POST', headers: { authorization: 'Bearer ' + bearer, 'content-type': 'application/json' } }); value.user = null; return value; }
  return { f, runtime, started, source, route, context, get lineage() { return lineage!; }, get token() { return token; }, original, dispose() { runtime.close(); f.store.close(); } };
}

describe('authenticated fresh native follow-up admission', () => {
  test('same-owner helper admission keeps the original human while provisioning fresh target credentials and F proof', async () => {
    const s = await setup();
    try {
      const helper: P.Bot = { ...s.f.bot, id: 'owned_helper_bot', profileId: 'lb-owned-helper', mainConversationId: '' }; s.f.store.put('bots', helper);
      s.f.store.setMetadata(`botMcp:${helper.id}`, { secretName: 'LEMON_BOT_HELPER_FIXTURE', encryptedToken: 'encrypted-helper-token', digest: 'helper-digest' });
      const candidate: NativeFollowupLineage = { ...s.lineage, runId: 'owned_helper_F', targetProfileId: helper.profileId, targetAgentId: helper.profileId, targetSessionKey: s.runtime.sessionKey(s.f.conversation, helper) };
      const original = s.f.rpc;
      s.f.rpc = async (method, params) => method === 'runs.followup.lineage.get' ? candidate : original(method, params);
      const response = await s.route.handler(s.context({ runId: candidate.runId }));
      expect(response).toMatchObject({ allow: true, invocation: { sharedMemoryGrant: false, invocationProof: { runId: candidate.runId, secretName: `lemon_bot/invocations/${candidate.runId}` }, invocationMcpServers: [{ name: 'lemon-bot', headers: { Authorization: 'Bearer ${LEMON_SECRET:LEMON_BOT_HELPER_FIXTURE}' } }] } });
      expect(s.f.store.require<P.Run>('runs', candidate.runId)).toMatchObject({ botId: helper.id, initiatorUserId: s.f.alice.userId });
      expect(s.f.store.metadata(`runPrincipal:${candidate.runId}`)).toEqual(s.f.alice);
      expect(s.f.calls.filter(call => call.method === 'node.secrets.set' && call.params.operationId === candidate.runId)).toHaveLength(1);
      expect(s.f.calls.filter(call => call.method === 'chat.send')).toHaveLength(1);
    } finally { s.dispose(); }
  });

  test('legacy ACLs cannot admit a foreign source, parent, helper Bot or host, or replay approval after ownership changes', async () => {
    for (const boundary of ['source', 'parent', 'target', 'host', 'cached'] as const) {
      const s = await setup();
      try {
        s.f.services.auth.bot = (_actor, botId) => s.f.store.require<P.Bot>('bots', botId);
        let candidate = { ...s.lineage, runId: `foreign_${boundary}_F` };
        if (boundary === 'cached') {
          const original = s.f.rpc;
          s.f.rpc = async (method, params) => method === 'runs.followup.lineage.get' ? candidate : original(method, params);
          expect(await s.route.handler(s.context({ runId: candidate.runId }))).toMatchObject({ allow: true });
        }
        if (boundary === 'source' || boundary === 'cached') s.f.store.put('bots', { ...s.f.bot, ownerUserId: s.f.bob.userId });
        if (boundary === 'target') {
          const foreign: P.Bot = { ...s.f.bot, id: 'foreign_helper_bot', profileId: 'lb-foreign-helper', ownerUserId: s.f.bob.userId };
          s.f.store.put('bots', foreign); candidate = { ...candidate, targetProfileId: foreign.profileId, targetAgentId: foreign.profileId };
        }
        if (boundary === 'parent') {
          const foreign: P.Bot = { ...s.f.bot, id: 'legacy_foreign_parent_bot', profileId: 'lb-foreign-parent', ownerUserId: s.f.bob.userId }; s.f.store.put('bots', foreign);
          const parent: P.Run = { ...s.started.run, id: 'legacy_same_actor_foreign_parent', botId: foreign.id }; s.f.store.put('runs', parent);
          const mapped = s.f.store.metadata<RuntimeMapping>(`runtimeRun:${s.started.run.id}`)!;
          s.f.store.setMetadata(`nativeRunProduct:${parent.id}`, parent.id); s.f.store.setMetadata(`runPrincipal:${parent.id}`, s.f.alice);
          s.f.store.setMetadata(`runtimeRun:${parent.id}`, { ...mapped, upstreamRunId: parent.id, executionRunId: parent.id, botId: foreign.id, profileId: foreign.profileId });
          s.f.store.setMetadata(`runtimeInvocation:${parent.id}`, s.source); s.f.store.setMetadata(`nativeRootSource:${parent.id}`, s.started.run.id);
          candidate = { ...candidate, parentRunId: parent.id };
        }
        if (boundary === 'host') s.f.store.put('machines', { ...s.f.machine, ownerUserId: s.f.bob.userId, accessUserIds: [s.f.alice.userId] });
        const before = s.f.calls.length; const original = s.f.rpc;
        s.f.rpc = async (method, params) => method === 'runs.followup.lineage.get' ? candidate : original(method, params);
        expect(await s.route.handler(s.context({ runId: candidate.runId }))).toEqual({ allow: false });
        expect(s.f.calls.slice(before).every(call => call.method === 'runs.followup.lineage.get' && !call.mutation)).toBe(true);
        if (boundary !== 'cached') expect(s.f.store.metadata(`nativeRunProduct:${candidate.runId}`)).toBeNull();
        expect(s.f.store.metadata(`runPrincipal:${s.started.run.id}`)).toEqual(s.f.alice);
      } finally { s.dispose(); }
    }
  });

  test('provisions a fixed destination proof before approval, retains actual principal, and never dispatches or replays native execution', async () => {
    const s = await setup();
    try {
      const original = s.f.rpc;
      s.f.rpc = async (method, params) => {
        if (method === 'node.secrets.set' && params.operationId === s.lineage.runId) {
          expect(s.f.store.require<P.Run>('runs', s.lineage.runId).status).toBe('reserved');
          expect(s.f.store.metadata(`runPrincipal:${s.lineage.runId}`)).toEqual(s.f.alice);
          expect(s.f.store.metadata<RuntimeMapping>(`runtimeRun:${s.lineage.runId}`)).toMatchObject({ upstreamRunId: s.lineage.runId, dispatched: false, nodeId: 'node_1' });
        }
        return original(method, params);
      };
      const response = await s.route.handler(s.context());
      expect(response).toMatchObject({ allow: true, invocation: { sharedMemoryGrant: false, invocationProof: { runId: s.lineage.runId, secretName: 'lemon_bot/invocations/' + s.lineage.runId } } });
      const replay = await s.route.handler(s.context()); expect(replay).toEqual(response);
      expect(s.f.calls.filter(call => call.method === 'node.secrets.set' && call.params.operationId === s.lineage.runId)).toHaveLength(1);
      expect(s.f.calls.filter(call => call.method === 'mcp.execution_names').every(call => !call.mutation && Object.keys(call.params).sort().join(',') === 'server,toolNames')).toBe(true);
      expect(s.f.calls.filter(call => call.method === 'chat.send')).toHaveLength(1);
      const proof = String(s.f.calls.find(call => call.method === 'node.secrets.set' && call.params.operationId === s.lineage.runId)!.params.value);
      expect(observeInvocation(s.f.services, proof)).toMatchObject({ id: s.lineage.runId, status: 'running' });
      s.f.store.setMetadata(`runtimePolicyFence:${s.f.bot.id}:${s.f.alice.userId}`, { state: 'outcome_unknown' });
      expect(() => observeInvocation(s.f.services, proof)).toThrow(ApiError);
      expect(await s.route.handler(s.context())).toEqual({ allow: false });
    } finally { s.dispose(); }
  });
  test('authentication and exact body fail before controller queries; private token never enters public Bot or callback response', async () => {
    const s = await setup();
    try {
      const before = s.f.calls.length;
      await expect(s.route.handler(s.context({ runId: s.lineage.runId }, 'wrong'))).rejects.toMatchObject({ code: 'unauthenticated' });
      await expect(s.route.handler(s.context({ runId: s.lineage.runId, userId: 'bob' }))).rejects.toMatchObject({ code: 'invalid_request' });
      expect(s.f.calls).toHaveLength(before);
      expect(JSON.stringify(s.f.store.require('bots', s.f.bot.id))).not.toContain(s.token);
      expect(JSON.stringify(await s.route.handler(s.context()))).not.toContain(s.token);
      const configured = s.f.calls.filter(call => call.method === 'profile.followup.admission.set').length;
      await configureNativeFollowupAdmission(s.f.services, s.f.bot);
      expect(s.f.calls.filter(call => call.method === 'profile.followup.admission.set')).toHaveLength(configured);
    } finally { s.dispose(); }
  });
  test('source-key spoof, another user parent, local/default placement, and disabled membership never mint a destination proof', async () => {
    const s = await setup();
    try {
      const queries = s.f.rpc;
      // Persist a legacy foreign parent rather than executing another human's Bot to manufacture one.
      const other: P.Run = { ...s.started.run, id: 'legacy_foreign_parent', initiatorUserId: s.f.bob.userId };
      const mapped = s.f.store.metadata<RuntimeMapping>(`runtimeRun:${s.started.run.id}`)!;
      s.f.store.put('runs', other); s.f.store.setMetadata(`nativeRunProduct:${other.id}`, other.id); s.f.store.setMetadata(`runPrincipal:${other.id}`, s.f.bob);
      s.f.store.setMetadata(`runtimeRun:${other.id}`, { ...mapped, upstreamRunId: other.id, executionRunId: other.id }); s.f.store.setMetadata(`runtimeInvocation:${other.id}`, s.source); s.f.store.setMetadata(`nativeRootSource:${other.id}`, s.started.run.id);
      const existingProofs = s.f.calls.filter(call => call.method === 'node.secrets.set').length;
      const variants: NativeFollowupLineage[] = [
        { ...s.lineage, sourceInvocationContextKey: 'spoofed_other_actor_key' },
        { ...s.lineage, targetNodeId: 'local' },
        { ...s.lineage, targetSessionKey: 'agent:default:other_user' },
        { ...s.lineage, parentRunId: other.id },
      ];
      for (let index = 0; index < variants.length; index++) {
        const candidate = { ...variants[index]!, runId: `native_denied_${index}` };
        s.f.rpc = async (method, params) => method === 'runs.followup.lineage.get' ? candidate : queries(method, params);
        expect(await s.route.handler(s.context({ runId: candidate.runId }))).toEqual({ allow: false });
        expect(s.f.store.metadata(`nativeRunProduct:${candidate.runId}`)).toBeNull();
      }
      s.f.rpc = queries;
      const member = s.f.store.require<P.Member>('members', s.f.alice.userId); s.f.store.put('members', { ...member, enabled: false });
      expect(await s.route.handler(s.context())).toEqual({ allow: false });
      expect(s.f.calls.filter(call => call.method === 'node.secrets.set')).toHaveLength(existingProofs);
    } finally { s.dispose(); }
  });
  test('unknown destination credential provisioning records uncertainty and cannot replay through duplicate admission', async () => {
    const s = await setup();
    try {
      const original = s.f.rpc;
      s.f.rpc = async (method, params) => { if (method === 'node.secrets.set' && params.operationId === s.lineage.runId) throw new ApiError('outcome_unknown', 'Receipt unavailable.', false); return original(method, params); };
      expect(await s.route.handler(s.context())).toEqual({ allow: false });
      expect(s.f.store.require<P.Run>('runs', s.lineage.runId).status).toBe('outcome_unknown');
      expect(await s.route.handler(s.context())).toEqual({ allow: false });
      expect(s.f.calls.filter(call => call.method === 'node.secrets.set' && call.params.operationId === s.lineage.runId)).toHaveLength(1);
    } finally { s.dispose(); }
  });
  test('unknown issuer configuration has no automatic mutation replay', async () => {
    const f = fixture(); f.services.lemon.methods.push('profile.followup.admission.set', 'runs.followup.lineage.get');
    f.rpc = async () => { throw new ApiError('outcome_unknown', 'Configuration reply lost.', false); };
    try {
      await expect(configureNativeFollowupAdmission(f.services, f.bot)).rejects.toMatchObject({ code: 'outcome_unknown' });
      await expect(configureNativeFollowupAdmission(f.services, f.bot)).rejects.toMatchObject({ code: 'outcome_unknown' });
      expect(f.calls).toHaveLength(1);
    } finally { f.store.close(); }
  });
});
