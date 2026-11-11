import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { ApiError } from '../../src/core/errors';
import { createRuntimeService, type InvocationContext, type RuntimeMapping, type ManagedRuntimeService } from '../../src/runtime/runs';
import { fixture, type TestRuntimeFixture } from './fixture';
import { botBindingDigest } from '../../src/core/approval-allowances';

interface ApprovalFixture extends TestRuntimeFixture { runtime: ManagedRuntimeService; cards: unknown[] }

function setup() {
  const f = fixture();
  const effective = f.services.integrations.effectivePolicy;
  f.services.integrations.effectivePolicy = async (...args) => ({ ...await effective(...args), rememberedApprovals: { chat: ['shell', 'files'], bot: [] } });
  const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
  const cards: unknown[] = [];
  f.services.gates.create = async <T>(_actor: unknown, _kind: unknown, input: unknown) => { cards.push(input); return { id: `card_${cards.length}` } as T; };
  const rpc = f.rpc;
  f.rpc = async (method, params) => method === 'exec.approval.resolve' ? { resolved: true, approvalId: params.approvalId, decision: params.decision, sessionKey: params.expectedSessionKey, runId: params.expectedRunId, approved: true, outcome: 'approved' } : rpc(method, params);
  return Object.assign(f, { runtime, cards });
}
async function start(f: ApprovalFixture, nonce: string) {
  return (await f.runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: nonce, text: 'work' })).run;
}
function seed(f: ApprovalFixture, run: P.Run) {
  const bound = f.store.metadata<RuntimeMapping>(`runtimeRun:${run.id}`)!;
  const contextKey = f.store.metadata<InvocationContext>(`runtimeInvocation:${bound.upstreamRunId}`)!.invocationContextKey;
  const allowance: P.ApprovalAllowance = f.services.resource('allowance', { scope: 'chat', botId: f.bot.id, conversationId: f.conversation.id, ownerUserId: f.alice.userId, toolGroups: ['terminal'], label: 'Terminal allowed in this chat', state: 'active', endedReason: null, endedAtMs: null, endedByUserId: null, sourceApprovalId: null, createdByUserId: f.alice.userId, useCount: 0, lastUsedAtMs: null });
  f.store.put('approvalAllowances', allowance); f.store.setMetadata(`approvalAllowanceBinding:${allowance.id}`, { contextKey });
  return allowance;
}
async function request(f: ApprovalFixture, run: P.Run, approvalId: string, tool = 'bash') {
  const bound = f.store.metadata<RuntimeMapping>(`runtimeRun:${run.id}`)!;
  await f.runtime.project('exec.approval.requested', { approvalId, runId: bound.executionRunId, sessionKey: bound.sessionKey, tool, action: { command: 'echo safe', path: 'safe.txt' }, expiresAtMs: f.services.now() + 60_000 });
}
describe('remembered runtime approvals', () => {
  test('owner messages retain context; bash and bash_output auto-answer once without cards or awaiting input', async () => {
    const f = setup();
    try {
      const first = await start(f, 'remembered_owner_message_001'); const allowance = seed(f, first);
      await request(f, first, 'auto_bash_1');
      const second = await start(f, 'remembered_owner_message_002');
      expect(f.store.metadata<InvocationContext>(`runtimeInvocation:${first.id}`)!.invocationContextKey).toBe(f.store.metadata<InvocationContext>(`runtimeInvocation:${second.id}`)!.invocationContextKey);
      await request(f, second, 'auto_output_2', 'bash_output');
      expect(f.cards).toHaveLength(0);
      expect(f.store.require<P.ApprovalAllowance>('approvalAllowances', allowance.id).useCount).toBe(2);
      expect(f.store.require<P.Run>('runs', second.id).status).not.toBe('awaiting_input');
      expect(f.calls.filter(call => call.method === 'exec.approval.resolve').every(call => call.params.decision === 'approve_once')).toBe(true);
    } finally { f.runtime.close(); f.store.close(); }
  });
  test('file changes and untrusted or unattended origins still show cards', async () => {
    for (const origin of ['owner_chat', 'external', 'routine', 'native_followup', 'other']) {
      const f = setup();
      try {
        const run = await start(f, `origin_message_${origin}_001`); seed(f, run);
        f.store.setMetadata(`runApprovalOrigin:${run.id}`, origin);
        await request(f, run, `origin_${origin}`, origin === 'owner_chat' ? 'write' : 'bash');
        expect(f.cards).toHaveLength(1);
      } finally { f.runtime.close(); f.store.close(); }
    }
  });
  test('retry-safe rejection creates a card; unknown outcome retains marker and warns without replay', async () => {
    for (const unknown of [false, true]) {
      const f = setup();
      try {
        const run = await start(f, 'approval_failure_owner_001'); seed(f, run); const rpc = f.rpc;
        f.rpc = async (method, params) => { if (method === 'exec.approval.resolve') throw new ApiError(unknown ? 'outcome_unknown' : 'upstream_unavailable', 'Rejected', !unknown); return rpc(method, params); };
        await request(f, run, 'failure_approval');
        expect(f.cards).toHaveLength(unknown ? 0 : 1);
        if (unknown) {
          await request(f, run, 'failure_approval');
          expect(f.calls.filter(call => call.method === 'exec.approval.resolve')).toHaveLength(1);
          expect(f.store.list<P.TranscriptEntry>('entries', entry => entry.kind === 'notice')).toHaveLength(1);
          expect(f.store.metadata<string>('remoteApproval:failure_approval')).toStartWith('allowance:');
        }
      } finally { f.runtime.close(); f.store.close(); }
    }
  });
  test('a different chat and a changed invocation epoch cannot borrow the allowance', async () => {
    for (const changedEpoch of [false, true]) {
      const f = setup();
      try {
        const first = await start(f, 'context_initial_owner_001'); const allowance = seed(f, first);
        if (changedEpoch) f.store.setMetadata(`botPolicySync:${f.bot.id}`, { state: 'acknowledged', revision: 2 });
        else {
          const other: P.Conversation = { ...f.conversation, id: 'other_conversation' };
          f.store.put('conversations', other); f.conversation = other;
        }
        const second = await start(f, 'context_changed_owner_002');
        await request(f, second, 'context_changed_approval');
        expect(f.cards).toHaveLength(1);
        if (changedEpoch) expect(f.store.require<P.ApprovalAllowance>('approvalAllowances', allowance.id)).toMatchObject({ state: 'ended' });
      } finally { f.runtime.close(); f.store.close(); }
    }
  });
  test('bot-wide approval auto-answers trusted origins and audits no command text, but external still asks', async () => {
    for (const origin of ['owner_chat', 'routine', 'native_followup', 'external']) {
      const f = setup();
      try {
        const effective = f.services.integrations.effectivePolicy;
        f.services.integrations.effectivePolicy = async (...args) => ({ ...await effective(...args), rememberedApprovals: { chat: ['shell', 'files'], bot: ['shell', 'files'] } });
        const run = await start(f, `botwide_${origin}_owner_001`);
        const chat = seed(f, run);
        const allowance: P.ApprovalAllowance = { ...chat, id: 'bot_allowance_runtime', scope: 'bot', conversationId: null };
        f.store.remove('approvalAllowances', chat.id);
        f.store.put('approvalAllowances', allowance);
        f.store.setMetadata(`approvalAllowanceBinding:${allowance.id}`, { bindingDigest: botBindingDigest(f.services, f.bot) });
        f.store.setMetadata(`runApprovalOrigin:${run.id}`, origin);
        const audits: unknown[] = [];
        const audit = f.services.audit;
        f.services.audit = (actor, action, resource, outcome, metadata) => { if (action === 'approval_allowance.use') audits.push(metadata); return audit(actor, action, resource, outcome, metadata); };
        await request(f, run, `botwide_${origin}`);
        expect(f.cards).toHaveLength(origin === 'external' ? 1 : 0);
        expect(audits).toEqual(origin === 'external' ? [] : [{ tool: 'bash', runId: run.id, origin }]);
      } finally { f.runtime.close(); f.store.close(); }
    }
  });
  test('external submission is marked external even in an owner DM', async () => {
    const f = setup();
    try {
      f.store.setMetadata(`externalSubmission:user:alice:${f.conversation.id}:external_owner_nonce_001`, { provider: 'x' });
      const run = await start(f, 'external_owner_nonce_001');
      expect(f.store.metadata(`runApprovalOrigin:${run.id}`)).toBe('external');
    } finally { f.runtime.close(); f.store.close(); }
  });
});
