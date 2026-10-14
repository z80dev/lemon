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
      const conversation: P.Conversation = { ...s.f.conversation, id: 'native_bob_source', ownerUserId: s.f.bob.userId, humanUserIds: [s.f.bob.userId] }; s.f.store.put('conversations', conversation);
      const other = await s.runtime.submit(s.f.bob, conversation, s.f.bot, { clientNonce: 'foreign_native_source_001', text: 'private work' });
      const existingProofs = s.f.calls.filter(call => call.method === 'node.secrets.set').length;
      const variants: NativeFollowupLineage[] = [
        { ...s.lineage, sourceInvocationContextKey: 'spoofed_other_actor_key' },
        { ...s.lineage, targetNodeId: 'local' },
        { ...s.lineage, targetSessionKey: 'agent:default:other_user' },
        { ...s.lineage, parentRunId: other.run.id },
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
