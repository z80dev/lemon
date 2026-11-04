import { afterEach, describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { chatFixture, alice, bob, type ChatFixture } from './conversations.fixture';
import { createAddressedAgentService } from '../../src/core/agent-addressing';
import { createConversation, type SubmissionContext } from '../../src/core/conversations';
import { ApiError } from '../../src/core/errors';

const nonce = 'agent_nonce_00000001';
interface TestReceipt extends P.AgentMessageReceipt { scope: string }
interface TestMessageRecord extends P.AgentMessageReceipt { id: string; scope: string; sourceResumeState: string | null; targetRunId: string | null; sourceConversationId: string | null; terminalSent: boolean }
interface Controller {
  sendCount: number;
  completeCount: number;
  call<T>(method: string, params?: Record<string, unknown>): Promise<T>;
  sendFrom(sourceId: string, target: string, text: string, messageId: string, scope?: string): Promise<P.AgentMessageReceipt>;
  completeFrom(messageId: string, status: P.AgentMessageStatus, response: string | null, scope?: string): Promise<void>;
}

function controller(fixture: ChatFixture, scope: string): Controller {
  const identities = new Map<string, P.AgentIdentity>();
  const receipts = new Map<string, TestReceipt>();
  identities.set(`session://carol`, { id: 'session://carol', name: 'carol', kind: 'session', label: 'Carol', status: 'idle' });
  const resolve = (target: string) => {
    const normalized = target.startsWith('@') ? target.slice(1).toLowerCase() : target.toLowerCase();
    return [...identities.values()].find(agent => agent.id === target || agent.name === normalized) ?? null;
  };
  const result = <T>(value: unknown) => value as T;
  const api: Controller = {
    sendCount: 0,
    completeCount: 0,
    async call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
      if (method === 'agent.identity.register') {
        const current = identities.get(String(params.id));
        const name = params.name === undefined ? current?.name ?? null : params.name as string | null;
        if (name && [...identities.values()].some(agent => agent.id !== params.id && agent.name === name)) throw new ApiError('conflict', 'Handle already exists.');
        const agent: P.AgentIdentity = { id: String(params.id), name, kind: 'bot', label: String(params.label), status: 'idle' };
        identities.set(agent.id, agent);
        return result<T>({ agent });
      }
      if (method === 'agent.identity.unregister') { identities.delete(String(params.id)); return result<T>({ removed: true, id: params.id }); }
      if (method === 'agent.identity.rename') {
        const agent = identities.get(String(params.id));
        if (!agent) throw new ApiError('not_found', 'Unknown agent.');
        const name = params.name as string | null;
        if (name && [...identities.values()].some(other => other.id !== agent.id && other.name === name)) throw new ApiError('conflict', 'Handle already exists.');
        Object.assign(agent, { name });
        return result<T>({ agent });
      }
      if (method === 'agent.identity.list') {
        const query = typeof params.query === 'string' ? params.query.toLowerCase() : '';
        const agents = [...identities.values()].filter(agent => !query || `${agent.name ?? ''} ${agent.label} ${agent.id}`.toLowerCase().includes(query)).slice(0, Number(params.limit ?? 100));
        return result<T>({ agents });
      }
      if (method === 'agent.message.send') return result<T>(await api.sendFrom(String(params.sourceId), String(params.target), String(params.text), String(params.messageId), String(params.scope ?? scope)));
      if (method === 'agent.message.get') {
        const receipt = receipts.get(String(params.messageId));
        if (!receipt || receipt.sourceId !== params.sourceId) throw new ApiError('not_found', 'Unknown message.');
        return result<T>(receipt);
      }
      if (method === 'agent.message.complete') {
        api.completeCount++;
        const receipt = receipts.get(String(params.messageId));
        if (!receipt) throw new ApiError('not_found', 'Unknown message.');
        receipt.status = params.status as P.AgentMessageStatus;
        if (params.runId) receipt.runId = String(params.runId);
        if (typeof params.response === 'string') receipt.response = params.response;
        if (receipt.status !== 'accepted') fixture.emit('agent.message.result', { ...receipt });
        return result<T>(receipt);
      }
      throw new Error(`Unexpected controller method ${method}`);
    },
    async sendFrom(sourceId, target, text, messageId, messageScope = scope) {
      api.sendCount++;
      const existing = receipts.get(messageId);
      if (existing) {
        if (existing.sourceId !== sourceId || existing.targetId !== resolve(target)?.id || existing.response && existing.response !== text) throw new ApiError('nonce_conflict', 'Message conflict.');
        return existing;
      }
      const targetAgent = resolve(target);
      if (!targetAgent) throw new ApiError('not_found', 'Unknown target.');
      const receipt: TestReceipt = { scope: messageScope, messageId, sourceId, targetId: targetAgent.id, status: 'accepted', runId: null, response: null };
      receipts.set(messageId, receipt);
      if (targetAgent.kind === 'bot') fixture.emit('agent.message.request', { messageId, sourceId, targetId: targetAgent.id, text });
      return receipt;
    },
    async completeFrom(messageId, status, response) {
      const receipt = receipts.get(messageId);
      if (!receipt) throw new ApiError('not_found', 'Unknown message.');
      await api.call('agent.message.complete', { messageId, status, response, runId: receipt.runId ?? 'native-run' });
    },
  };
  return api;
}

async function until(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Promise.resolve();
  }
  throw new Error('Condition did not become true after queued work settled.');
}

async function setup() {
  const fixture = chatFixture();
  const source = fixture.addBot('source');
  const target = fixture.addBot('target');
  const lead = fixture.addBot('lead');
  const sourceRoom = createConversation(fixture.services, alice, { clientNonce: nonce, kind: 'dm', botIds: [source.id] });
  const targetRoom = createConversation(fixture.services, alice, { clientNonce: nonce, kind: 'dm', botIds: [target.id] });
  const leadRoom = createConversation(fixture.services, alice, { clientNonce: nonce, kind: 'dm', botIds: [lead.id] });
  fixture.store.put('members', { ...fixture.store.require<P.Member>('members', 'alice'), role: 'owner' });
  const scope = `bot:${fixture.store.metadata<string>('instanceId')}:alice`;
  const control = controller(fixture, scope);
  fixture.services.lemon.methods = ['agent.identity.register', 'agent.identity.unregister', 'agent.identity.rename', 'agent.identity.list', 'agent.message.send', 'agent.message.get', 'agent.message.complete'];
  fixture.services.lemon.call = control.call;
  const service = createAddressedAgentService(fixture.services);
  fixture.services.addressedAgents = service;
  await service.registerAll();
  await service.rename(alice, target.id, 'target');
  await service.rename(alice, lead.id, 'lead');
  return { fixture, service, control, source, target, lead, sourceRoom, targetRoom, leadRoom, scope };
}

async function finishTarget(fixture: ChatFixture, target: P.Bot, messageId: string, text: string): Promise<void> {
  const run = fixture.store.list<P.Run>('runs', value => value.botId === target.id && value.clientNonce === messageId)[0];
  expect(run).toBeDefined();
  const entry = fixture.services.entry(alice, run!.conversationId, { kind: 'message', role: 'assistant', text, streaming: false, attachmentIds: [], actor: { kind: 'bot', id: target.id, displayName: target.name }, runId: run!.id });
  fixture.store.setMetadata(`runtimeRun:${run!.id}`, { assistantEntryId: entry.id });
  const terminal = fixture.services.update(run!, { status: 'succeeded' as const, completedAtMs: fixture.services.now() });
  fixture.store.put('runs', terminal);
  fixture.services.events.emit('run.upserted', terminal, { conversationId: terminal.conversationId, botId: terminal.botId });
  await until(() => fixture.store.list<TestMessageRecord>('agentMessages').some(record => record.messageId === messageId && record.terminalSent));
}

const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

describe('addressed Bot agents', () => {
  test('owner ACL, pinned operator scope, rename persistence and collisions', async () => {
    const { fixture, service, source, target } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    expect(() => service.identity(bob, source.id)).toThrow(ApiError);
    const privateIdentity = service.identity(alice, source.id).agent;
    expect(privateIdentity.id).toBe(`bot://${fixture.store.metadata<string>('instanceId')}/source`);
    expect(fixture.store.list<TestMessageRecord>('agentMessages')).toHaveLength(0);

    fixture.services.config.operator.namedAgentOperatorUserId = 'alice';
    await service.registerAll();
    expect(fixture.store.metadata<{ scope: string }>(`agentRegistration:${source.id}`)?.scope).toBe('operator');
    fixture.store.put('workspaces', { ...fixture.store.require<P.Workspace>('workspaces', 'workspace'), ownerUserId: 'bob' });
    await service.registerAll();
    expect(fixture.store.metadata<{ scope: string }>(`agentRegistration:${source.id}`)?.scope).toBe(`bot:${fixture.store.metadata<string>('instanceId')}:alice`);

    const renamed = await service.rename(alice, source.id, '@Source_One');
    expect(renamed.agent.name).toBe('source_one');
    expect(fixture.store.require<P.Bot>('bots', source.id).name).toBe('source');
    expect(fixture.store.metadata<string>(`agentHandle:${source.id}`)).toBe('source_one');
    await expect(service.rename(alice, target.id, '@source_one')).rejects.toThrow(ApiError);
    expect(fixture.store.metadata<string>(`agentHandle:${target.id}`)).toBe('target');
    const cleared = await service.rename(alice, source.id, null);
    expect(cleared.agent.name).toBeNull();
  });

  test('named send replay, unknown target and lost handle acknowledgement reconcile without redispatch', async () => {
    const { fixture, service, control, source, sourceRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    const input: P.AgentMessageSend = { clientNonce: nonce, target: '@target', text: 'Investigate', conversationId: sourceRoom.id };
    const first = await service.send(alice, source.id, input);
    expect(first.status).toBe('accepted');
    expect(first.targetId).toBe(`bot://${fixture.store.metadata<string>('instanceId')}/target`);
    await service.send(alice, source.id, input);
    expect(control.sendCount).toBe(1);
    await expect(service.send(alice, source.id, { ...input, text: 'Changed' })).rejects.toThrow(ApiError);
    await expect(service.send(alice, source.id, { ...input, clientNonce: 'agent_nonce_00000002', target: '@missing' })).rejects.toThrow(ApiError);
    expect(control.sendCount).toBe(2);
    expect(fixture.submissions.filter(item => item.message.clientNonce === 'agent_nonce_00000002')).toHaveLength(0);

    const pending = fixture.store.list<TestMessageRecord>('agentMessages', record => record.messageId === nonce)[0]!;
    fixture.store.put('agentMessages', { ...pending, targetId: '@target', status: 'outcome_unknown' });
    const targetId = `bot://${fixture.store.metadata<string>('instanceId')}/target`;
    await control.completeFrom(nonce, 'completed', 'Done');
    await until(() => fixture.submissions.some(item => item.message.clientNonce.startsWith('agent_result_')));
    const record = fixture.store.require<TestMessageRecord>('agentMessages', pending.id);
    expect(record.targetId).toBe(targetId);
    expect(record.status).toBe('completed');
    expect(control.sendCount).toBe(2);
  });

  test('terminal result before send acknowledgement remains terminal and resumes once', async () => {
    const { fixture, service, control, source, target, sourceRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    const acknowledged = Promise.withResolvers<void>();
    const originalCall = control.call;
    let delayed = true;
    fixture.services.lemon.call = async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
      if (method === 'agent.message.send' && delayed) {
        delayed = false;
        const receipt = structuredClone(await originalCall<T>(method, params));
        await acknowledged.promise;
        return receipt;
      }
      return originalCall<T>(method, params);
    };
    const pending = service.send(alice, source.id, { clientNonce: nonce, target: '@target', text: 'Race question', conversationId: sourceRoom.id });
    await until(() => fixture.submissions.some(item => item.bot.id === target.id));
    await control.completeFrom(nonce, 'completed', 'Early answer');
    await until(() => fixture.submissions.some(item => item.bot.id === source.id && item.message.clientNonce.startsWith('agent_result_')));
    acknowledged.resolve();
    const receipt = await pending;
    expect(receipt.status).toBe('completed');
    expect(receipt.response).toBe('Early answer');
    expect(fixture.submissions.filter(item => item.bot.id === source.id)).toHaveLength(1);
  });

  test('Bot-to-Bot request and terminal response reuse both main conversations without loops', async () => {
    const { fixture, service, control, source, target, sourceRoom, targetRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    const receipt = await service.send(alice, source.id, { clientNonce: nonce, target: '@target', text: 'Peer question' });
    await until(() => fixture.submissions.some(item => item.bot.id === target.id));
    const incoming = fixture.submissions.find(item => item.bot.id === target.id)!;
    expect(incoming.conversation.id).toBe(targetRoom.id);
    expect(incoming.conversation.kind).toBe('dm');
    expect((incoming.metadata as SubmissionContext).noHandoff).toBe(true);
    const peerEntry = fixture.store.list<P.TranscriptEntry>('entries', entry => entry.conversationId === targetRoom.id && entry.clientNonce === nonce)[0]!;
    expect(fixture.store.metadata<{ kind: string }>(`entryAuthority:${peerEntry.id}`)?.kind).toBe('bot');
    const reserved = fixture.store.list<TestMessageRecord>('agentMessages')[0]!;
    fixture.store.put('agentMessages', { ...reserved, targetRunId: null });
    const targetRun = fixture.store.list<P.Run>('runs', run => run.clientNonce === nonce && run.botId === target.id)[0]!;
    fixture.store.setMetadata(`agentTargetRun:${targetRun.id}`, null);
    const sendsBeforeRebind = control.sendCount;
    await service.reconcile();
    expect(control.sendCount).toBe(sendsBeforeRebind);
    expect(fixture.store.list<TestMessageRecord>('agentMessages')[0]?.targetRunId).not.toBeNull();
    expect(fixture.submissions).toHaveLength(1);
    await finishTarget(fixture, target, nonce, 'Peer answer');
    await until(() => fixture.submissions.some(item => item.bot.id === source.id && item.message.clientNonce.startsWith('agent_result_')));
    const resumed = fixture.submissions.find(item => item.bot.id === source.id)!;
    expect(resumed.conversation.id).toBe(sourceRoom.id);
    expect(resumed.message.mentions).toEqual([source.id]);
    expect((resumed.metadata as SubmissionContext).noHandoff).toBe(true);
    expect(fixture.submissions).toHaveLength(2);
    expect(receipt.status).toBe('accepted');
    const status = await service.status(alice, source.id, nonce);
    expect(status.status).toBe('completed');
    expect(status.response).toBe('Peer answer');
    expect(fixture.submissions).toHaveLength(2);
  });

  test('source response returns to the exact group and non-lead Bot', async () => {
    const { fixture, service, control, source, target, lead } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    const group = createConversation(fixture.services, alice, { clientNonce: nonce, kind: 'group', botIds: [lead.id, source.id], leadBotId: lead.id });
    await service.send(alice, source.id, { clientNonce: nonce, target: '@target', text: 'Group question', conversationId: group.id });
    await until(() => fixture.submissions.some(item => item.bot.id === target.id));
    await control.completeFrom(nonce, 'completed', 'Group answer');
    await until(() => fixture.submissions.some(item => item.bot.id === source.id && item.conversation.id === group.id));
    const resumed = fixture.submissions.find(item => item.bot.id === source.id)!;
    expect(resumed.conversation.id).toBe(group.id);
    expect(resumed.message.mentions).toEqual([source.id]);
    expect(fixture.store.list<P.Conversation>('conversations', room => room.kind === 'task')).toHaveLength(0);
  });

  test('TUI targets complete and Bot sources receive TUI replies in their original room', async () => {
    const { fixture, service, control, source, target, sourceRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    await control.sendFrom('session://carol', '@target', 'Question from TUI', nonce);
    await until(() => fixture.submissions.some(item => item.bot.id === target.id));
    await finishTarget(fixture, target, nonce, 'Answer for TUI');
    expect(fixture.submissions.filter(item => item.bot.id === source.id)).toHaveLength(0);

    const second = 'agent_nonce_00000002';
    const outgoing = await service.send(alice, source.id, { clientNonce: second, target: '@carol', text: 'Question for TUI', conversationId: sourceRoom.id });
    expect(outgoing.status).toBe('accepted');
    await control.completeFrom(second, 'completed', 'TUI answer');
    await until(() => fixture.submissions.some(item => item.bot.id === source.id && item.message.clientNonce.startsWith('agent_result_')));
    const resumed = fixture.submissions.find(item => item.bot.id === source.id)!;
    expect(resumed.conversation.id).toBe(sourceRoom.id);
    expect(resumed.message.text).toContain('TUI answer');
  });

  test('scope revocation redacts completion and prevents source resume; old daemons fail only on feature use', async () => {
    const { fixture, service, control, source, sourceRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    await service.send(alice, source.id, { clientNonce: nonce, target: '@carol', text: 'Private question', conversationId: sourceRoom.id });
    fixture.store.put('members', { ...fixture.store.require<P.Member>('members', 'alice'), enabled: false });
    await control.completeFrom(nonce, 'completed', 'Must not leak');
    await until(() => fixture.store.metadata<{ pending: boolean }>('agentBridgeProjectionFailure')?.pending === true);
    expect(fixture.submissions.filter(item => item.bot.id === source.id)).toHaveLength(0);
    expect(fixture.store.list<TestMessageRecord>('agentMessages')[0]?.sourceResumeState).toBeNull();

    fixture.store.put('members', { ...fixture.store.require<P.Member>('members', 'alice'), enabled: true });
    fixture.services.lemon.methods = [];
    expect(service.identity(alice, source.id).agent.kind).toBe('bot');
    await expect(service.list(alice, source.id)).rejects.toMatchObject({ code: 'capability_unavailable' });
  });

  test('owner transfer redacts target completion and blocks old-scope source reconciliation', async () => {
    const { fixture, service, control, source, target, sourceRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    fixture.services.config.operator.namedAgentOperatorUserId = 'alice';
    await service.registerAll();
    await control.sendFrom('session://carol', '@target', 'Operator question', nonce, 'operator');
    await until(() => fixture.submissions.some(item => item.bot.id === target.id));
    const second = 'agent_nonce_00000002';
    await service.send(alice, source.id, { clientNonce: second, target: '@carol', text: 'Pending operator message', conversationId: sourceRoom.id });

    fixture.store.put('workspaces', { ...fixture.store.require<P.Workspace>('workspaces', 'workspace'), ownerUserId: 'bob' });
    await finishTarget(fixture, target, nonce, 'Must not cross scopes');
    const incoming = fixture.store.list<TestMessageRecord>('agentMessages').find(record => record.messageId === nonce)!;
    expect(incoming.status).toBe('failed');
    expect(incoming.response).toBeNull();

    let gets = 0;
    const originalCall = control.call;
    fixture.services.lemon.call = async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
      if (method === 'agent.message.get') gets++;
      return originalCall<T>(method, params);
    };
    await service.reconcile();
    expect(gets).toBe(0);
    expect(fixture.submissions.filter(item => item.bot.id === source.id)).toHaveLength(0);
    expect(fixture.store.list<TestMessageRecord>('agentMessages').find(record => record.messageId === second)?.sourceResumeState).toBeNull();
  });

  test('chat commands leave visible receipts without submitting their command text as prompts', async () => {
    const { fixture, service, source, sourceRoom } = await setup();
    cleanups.push(() => { service.close(); fixture.store.close(); });
    const roster = await service.command(alice, sourceRoom.id, { clientNonce: nonce, text: '/agents' });
    expect(roster?.entries[0]?.kind).toBe('notice');
    expect(roster?.runs).toHaveLength(0);
    const named = await service.command(alice, sourceRoom.id, { clientNonce: 'agent_nonce_00000002', text: '/agent-name helper' });
    expect(named?.entries[0]?.kind).toBe('notice');
    expect(fixture.store.metadata<string>(`agentHandle:${source.id}`)).toBe('helper');
    const sent = await service.command(alice, sourceRoom.id, { clientNonce: 'agent_nonce_00000003', text: '/tell @target hello' });
    expect(sent?.entries[0]?.kind).toBe('notice');
    await until(() => fixture.submissions.some(item => item.bot.id === 'target'));
    expect(fixture.submissions).toHaveLength(1);
    expect(fixture.submissions[0]!.message.text).toContain('hello');
    expect(fixture.submissions[0]!.message.text).not.toContain('/tell');
  });
});
