// Preprovisioned fixtures deliberately skip unrelated Bot creation/HTTPS enrollment.
// Exercises real backend REST routing, authentication, nonce journal, owner ACL,
// addressed service and its authenticated controller connection. No mocked RPCs.
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { loadConfiguration, createPrivateCodec } from '../products/lemon_bot/backend/src/core/config';
import { Store } from '../products/lemon_bot/backend/src/core/store';
import { installHelpers } from '../products/lemon_bot/backend/src/core/helpers';
import { createMutationService } from '../products/lemon_bot/backend/src/core/mutations';
import { createAccessService } from '../products/lemon_bot/backend/src/core/auth';
import { createEventService } from '../products/lemon_bot/backend/src/core/events';
import { createAddressedAgentService, createAddressedAgentRoutes } from '../products/lemon_bot/backend/src/core/agent-addressing';
import { createBotRoutes } from '../products/lemon_bot/backend/src/core/bots';
import { createConversationRoutes } from '../products/lemon_bot/backend/src/core/conversations';
import { createAccountRoutes } from '../products/lemon_bot/backend/src/core/accounts';
import { createSyncRoutes } from '../products/lemon_bot/backend/src/core/sync';
import { createRealtime, type RealtimeData } from '../products/lemon_bot/backend/src/core/realtime';
import { createIntegrationServices } from '../products/lemon_bot/backend/src/integrations/index';
import { createIdentityRoutes } from '../products/lemon_bot/backend/src/enterprise/identity';
import { createLemonService } from '../products/lemon_bot/backend/src/runtime/lemon';
import { createRuntimeService } from '../products/lemon_bot/backend/src/runtime/runs';
import { Router } from '../products/lemon_bot/backend/src/core/router';
import type { BackendServices } from '../products/lemon_bot/backend/src/core/services';
import type * as P from '../products/lemon_bot/contracts/protocol';

export async function productAddressedSmoke(manifest: { root: string; url: string; credentialFile: string; cwd: string; product: string; alice: string }, operatorToken: string, nativeId: string): Promise<void> {
  const dataDir = join(manifest.root, 'product');
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  // This is the trusted private operator file, never a product UI mutation.
  await writeFile(join(dataDir, 'config.json'), JSON.stringify({ version: 1, namedAgentOperatorUserId: 'smoke-owner' }), { mode: 0o600 });
  const { config, key } = await loadConfiguration({
    LEMON_BOT_DATA_DIR: dataDir,
    LEMON_BOT_CONTROL_URL: manifest.url,
    LEMON_BOT_OPERATOR_TOKEN: operatorToken,
    LEMON_BOT_PUBLIC_URL: 'http://127.0.0.1:4080',
  });
  // Assemble the production owners needed by these routes, without unrelated
  // background machine refresh/provisioning workers changing fixture placement.
  const store = new Store(join(dataDir, 'product.sqlite'));
  const s = { config, store, ...createPrivateCodec(key) } as unknown as BackendServices;
  installHelpers(s);
  s.mutations = createMutationService(s, key);
  s.auth = createAccessService(s);
  s.events = createEventService(s);
  s.lemon = createLemonService(config);
  s.integrations = createIntegrationServices(s);
  const runtime = createRuntimeService(s);
  s.runtime = runtime;
  // This fixture replaces managed-runtime admission and node-inventory
  // reconciliation: preprovisioned local router/native sessions replace remote
  // enrollment, TLS and MCP invocation proof. Production authorization,
  // provenance, nonces, execution-event projection and addressed handlers remain.
  runtime.sessionKey = () => manifest.product;
  runtime.submit = async (actor, room, bot, message, context) => {
    s.auth.bot(actor, bot.id);
    s.auth.conversation(actor, room.id);
    if (bot.ownerUserId !== 'smoke-owner' || actor.userId !== bot.ownerUserId || room.id !== bot.mainConversationId) throw new Error('Unexpected fixture execution scope.');
    const run: P.Run = s.resource('run', { conversationId: room.id, botId: bot.id, initiatorUserId: actor.userId, clientNonce: message.clientNonce, status: 'running', startedAtMs: s.now(), completedAtMs: null, error: null, routineRunId: null });
    const machine = s.store.require<P.Machine>('machines', bot.machineId);
    s.store.put('runs', run);
    s.store.setMetadata(`runPrincipal:${run.id}`, actor);
    s.store.setMetadata(`nativeRunProduct:${run.id}`, run.id);
    s.store.setMetadata(`runtimeRun:${run.id}`, { upstreamRunId: run.id, executionRunId: run.id, sessionKey: manifest.product, profileId: bot.profileId, nodeId: machine.nodeId, conversationId: room.id, botId: bot.id, assistantEntryId: null, deltaSeq: 0, deltaGap: false, dispatched: true });
    context?.nonceResourceIds.push(run.id);
    const admitted = await s.lemon.call<{ runId: string; sessionKey: string; effectiveMode: string }>('chat.send', { runId: run.id, sessionKey: manifest.product, prompt: message.text, agentId: 'default', cwd: manifest.cwd, queueMode: 'queue' }, { mutation: true });
    if (admitted.runId !== run.id || admitted.sessionKey !== manifest.product || !['new_run', 'queued'].includes(admitted.effectiveMode)) throw new Error('Fixture native submission changed execution identity.');
    const delivery: P.MessageReceipt['delivery'][number] = { botId: bot.id, runId: run.id, targetRunId: null, requestedMode: message.mode ?? 'followup', effectiveMode: admitted.effectiveMode === 'queued' ? 'queued' : 'started' };
    s.store.setMetadata(`runDelivery:${run.id}`, delivery);
    return { run: s.store.require<P.Run>('runs', run.id), delivery };
  };
  s.addressedAgents = createAddressedAgentService(s);
  runtime.reconcile = () => s.addressedAgents.reconcile();
  const router = new Router(s);
  router.register([...createAddressedAgentRoutes(s), ...createBotRoutes(s), ...createConversationRoutes(s), ...createAccountRoutes(s), ...createSyncRoutes(s), ...createIdentityRoutes(s)]);
  const check = (value: unknown, message: string): void => {
    if (!value) {
      console.error(JSON.stringify({ productSmokeAssertion: message }));
      throw new Error('Product smoke assertion failed.');
    }
  };
  async function until<T>(probe: () => Promise<T>, predicate: (value: T) => boolean, label: string): Promise<T> {
    const expires = Date.now() + 45_000;
    for (;;) {
      const result = await probe();
      if (predicate(result)) return result;
      if (Date.now() >= expires) throw new Error(`Timed out: ${label}`);
      await Bun.sleep(25);
    }
  }
  try {
    const workspace: P.Workspace = s.resource('workspace', { name: 'Offline smoke', ownerUserId: 'smoke-owner', enabled: true, timezone: 'UTC' });
    s.store.put('workspaces', workspace);
    s.store.setMetadata('workspaceId', workspace.id);
    s.store.setMetadata('instanceId', crypto.randomUUID());

    function fixture(userId: string, role: P.Role): P.Bot {
      const user: P.User = { ...s.resource('user', {
        email: `${userId}@example.invalid`, displayName: userId, avatarAttachmentId: null,
        preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false },
        notifications: { enabled: false, sound: false, previews: false, completed: false, needsInput: false },
      }), id: userId };
      s.store.put('users', user);
      s.store.put('members', s.resource('member', { userId, email: user.email, displayName: userId, role, enabled: true }));
      const machine: P.Machine = s.resource('machine', { nodeId: `fixture-${userId}`, nodeName: `fixture-${userId}`, name: 'Preprovisioned offline smoke fixture', ownerUserId: userId, accessUserIds: [], status: 'online', lastSeenAtMs: s.now(), labels: {}, botIds: [] });
      s.store.put('machines', machine);
      const bot: P.Bot = s.resource('bot', {
        ownerUserId: userId, machineId: machine.id, profileId: `lb-fixture-${userId}`, name: `Display ${userId}`, title: '', job: '', instructions: '',
        avatar: { kind: 'character', shape: 'circle', color: '#112233', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null,
        skillIds: [], referenceAttachmentIds: [], mainConversationId: s.id('conversation'),
        sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: false }, activity: 'idle', activeRunIds: [],
      });
      s.store.put('bots', bot);
      const room: P.Conversation = { ...s.resource('conversation', { kind: 'dm', name: bot.name, botIds: [bot.id], ownerUserId: userId, parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] }), id: bot.mainConversationId };
      s.store.put('conversations', room);
      s.store.put('machines', { ...machine, botIds: [bot.id] });
      return bot;
    }
    const owner = fixture('smoke-owner', 'owner');
    const admin = fixture('smoke-admin', 'admin');
    const member = fixture('smoke-member', 'member');
    const tokens = new Map<string, string>();
    for (const bot of [owner, admin, member]) tokens.set(bot.ownerUserId, (await s.auth.session(bot.ownerUserId)).token);
    const deadline = Date.now() + 20_000;
    s.lemon.start();
    while (!s.lemon.connected && Date.now() < deadline) await Bun.sleep(25);
    check(s.lemon.connected, 'Product did not authenticate to isolated controller.');
    await s.addressedAgents.registerAll();

    async function request<T>(who: P.Bot, method: string, path: string, body?: unknown, status = 200): Promise<T> {
      const response = await router.fetch(new Request(`${config.publicUrl}/v1${path}`, {
        method, headers: { Authorization: `Bearer ${tokens.get(who.ownerUserId)!}`, 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      }));
      const payload = await response.json();
      if (response.status !== status) console.error(JSON.stringify({ productSmokeErrorCode: payload?.error?.code ?? 'unclassified' }));
      check(response.status === status, `Product ${method} ${path} returned ${response.status}, expected ${status}.`);
      return payload as T;
    }
    const identity = await request<{ agent: P.AgentIdentity }>(owner, 'GET', `/bots/${owner.id}/agent-identity`);
    check(identity.agent.id.startsWith('bot://'), 'Product returned no stable Bot address.');
    const rename = { clientNonce: crypto.randomUUID(), name: 'product-carol' };
    const named = await request<{ agent: P.AgentIdentity }>(owner, 'PATCH', `/bots/${owner.id}/agent-identity`, rename);
    check(named.agent.id === identity.agent.id && named.agent.name === 'product-carol', 'Product handle rename changed identity.');
    const replay = await request<{ agent: P.AgentIdentity }>(owner, 'PATCH', `/bots/${owner.id}/agent-identity`, rename);
    check(replay.agent.id === named.agent.id && replay.agent.name === named.agent.name, 'Product nonce replay changed the handle.');
    const botAfter = await request<P.Bot>(owner, 'GET', `/bots/${owner.id}`);
    check(botAfter.name === owner.name && botAfter.mainConversationId === owner.mainConversationId, 'Handle rename changed display name or main conversation.');
    const linked = await request<{ agents: P.AgentIdentity[] }>(owner, 'GET', `/bots/${owner.id}/agents`);
    check(linked.agents.some(agent => agent.id === nativeId), 'Pinned canonical owner did not discover operator peer.');
    const seed = await request<P.MessageReceipt>(owner, 'POST', `/conversations/${owner.mainConversationId}/messages`, { clientNonce: crypto.randomUUID(), text: 'SMOKE_SEED_PRODUCT PRODUCT_PRIVATE=indigo' }, 202);
    check(seed.runs.length === 1, 'Product seed did not start one actual native run.');
    await until(async () => s.store.require<P.Run>('runs', seed.runs[0]!.id), run => run.status === 'succeeded', 'product seed native context');

    const send = { clientNonce: crypto.randomUUID(), target: nativeId, text: 'SMOKE_PRODUCT_TO_BOB' };
    const outgoing = await request<P.AgentMessageReceipt>(owner, 'POST', `/bots/${owner.id}/agent-messages`, send, 202);
    const outgoingReplay = await request<P.AgentMessageReceipt>(owner, 'POST', `/bots/${owner.id}/agent-messages`, send, 202);
    check(outgoingReplay.messageId === outgoing.messageId, 'Product nonce replay duplicated addressed submission.');
    const completed = await until(() => request<P.AgentMessageReceipt>(owner, 'GET', `/bots/${owner.id}/agent-messages/${outgoing.messageId}`), value => value.status !== 'accepted', 'product to native result');
    check(completed.status === 'completed' && completed.response === 'PRODUCT_BOB_REPLY=violet', 'Product source lost actual native response.');
    await until(async () => s.store.list<P.TranscriptEntry>('entries', entry => entry.conversationId === owner.mainConversationId), entries => entries.some(entry => entry.kind === 'message' && entry.text === 'Product owner observed Bob in original context.'), 'product source original-context followup');

    const inboundId = crypto.randomUUID();
    const fromNative = await s.lemon.call<P.AgentMessageReceipt>('agent.message.send', { messageId: inboundId, sourceId: `session://${manifest.alice}`, target: '@product-carol', text: 'SMOKE_PRODUCT_QUERY' }, { mutation: true });
    check(fromNative.messageId === inboundId, 'Native-to-product admission changed message ID.');
    const inbound = await until(() => s.lemon.call<P.AgentMessageReceipt>('agent.message.get', { messageId: inboundId, sourceId: `session://${manifest.alice}` }), value => value.status !== 'accepted', 'native to product result');
    check(inbound.status === 'completed' && inbound.response === 'PRODUCT_REPLY=indigo', 'Product target lost its existing native context.');
    const peerEntries = s.store.list<P.TranscriptEntry>('entries', entry => entry.conversationId === owner.mainConversationId && entry.kind === 'message' && entry.text.includes('SMOKE_PRODUCT_QUERY'));
    check(peerEntries.length === 1 && peerEntries[0]!.actor.kind === 'bot' && peerEntries[0]!.actor.id === `session://${manifest.alice}` && s.store.metadata<{ kind: string }>(`entryAuthority:${peerEntries[0]!.id}`)?.kind === 'bot', 'Addressed peer text lost provenance or acquired human authority.');
    await until(() => s.lemon.call<{ messages: unknown[] }>('chat.history', { sessionKey: manifest.alice, cwd: manifest.cwd, limit: 200 }), value => JSON.stringify(value).includes('Alice observed product response in original context.'), 'native source product response');
    for (const other of [admin, member]) {
      await request(other, 'GET', `/bots/${other.id}/agent-identity`);
      const roster = await request<{ agents: P.AgentIdentity[] }>(other, 'GET', `/bots/${other.id}/agents`);
      check(!roster.agents.some(agent => agent.id === nativeId || agent.id === identity.agent.id), 'Private product scope exposed operator identities.');
      const denied = await router.fetch(new Request(`${config.publicUrl}/v1/bots/${owner.id}/agent-identity`, { headers: { Authorization: `Bearer ${tokens.get(other.ownerUserId)!}` } }));
      check([403, 404].includes(denied.status), 'Foreign product principal read owner Bot identity.');
      const deniedSend = await router.fetch(new Request(`${config.publicUrl}/v1/bots/${owner.id}/agent-messages`, { method: 'POST', headers: { Authorization: `Bearer ${tokens.get(other.ownerUserId)!}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ clientNonce: crypto.randomUUID(), target: nativeId, text: 'Forbidden foreign-source intent.' }) }));
      check([403, 404].includes(deniedSend.status), 'Foreign product principal sent as owner Bot.');
      await request<P.ErrorEnvelope>(other, 'POST', `/bots/${other.id}/agent-messages`, { clientNonce: crypto.randomUUID(), target: nativeId, text: 'Private scope must not cross into operator.' }, 404);
    }
    const adminMember = s.auth.member(admin.ownerUserId);
    store.put('members', s.update(adminMember, { role: 'owner' as const }));
    store.put('workspaces', s.update(workspace, { ownerUserId: admin.ownerUserId }));
    await s.addressedAgents.registerAll();
    for (const transferred of [owner, admin]) {
      const roster = await request<{ agents: P.AgentIdentity[] }>(transferred, 'GET', `/bots/${transferred.id}/agents`);
      check(!roster.agents.some(agent => agent.id === nativeId), 'Ownership transfer automatically retained or reassigned operator custody.');
    }
    store.put('members', adminMember);
    store.put('workspaces', workspace);
    // Trusted fixture config changes exercise fail-closed derivation without a
    // public endpoint capable of granting operator custody.
    config.operator.namedAgentOperatorUserId = 'smoke-admin';
    await s.addressedAgents.registerAll();
    const wrongPin = await request<{ agents: P.AgentIdentity[] }>(owner, 'GET', `/bots/${owner.id}/agents`);
    check(!wrongPin.agents.some(agent => agent.id === nativeId), 'Wrong operator pin retained operator discovery.');
    delete config.operator.namedAgentOperatorUserId;
    await s.addressedAgents.registerAll();
    const unlinked = await request<{ agents: P.AgentIdentity[] }>(owner, 'GET', `/bots/${owner.id}/agents`);
    check(!unlinked.agents.some(agent => agent.id === nativeId), 'Unset operator pin exposed operator sessions.');
    console.log(JSON.stringify({ productAddressedSmoke: 'passed', realREST: true, realAuthAndACL: true, realNonceJournal: true, realPeerProvenance: true, nativeRequestReply: true, operatorPin: true, ownerTransferRevokes: true, privateScopes: true, managedProof: false }));
    if (process.env.LEMON_NAMED_SMOKE_KEEP_ALIVE === '1') {
      config.operator.namedAgentOperatorUserId = 'smoke-owner';
      await s.addressedAgents.registerAll();
      const realtime = createRealtime(s);
      const server = Bun.serve<RealtimeData>({
        hostname: '127.0.0.1', port: 0,
        fetch(request, server) {
          if (new URL(request.url).pathname === '/v1/realtime' && server.upgrade(request, { data: realtime.data() })) return;
          return router.fetch(request);
        },
        websocket: realtime.websocket,
      });
      config.publicUrl = `http://127.0.0.1:${server.port}`;
      const password = `smoke-${crypto.randomUUID()}`;
      store.put('credentials', { id: owner.ownerUserId, passwordHash: await Bun.password.hash(password, { algorithm: 'argon2id' }) });
      const statePath = join(manifest.root, 'ui-fixture.json');
      await writeFile(statePath, JSON.stringify({ pid: process.pid, backendUrl: config.publicUrl, controllerUrl: manifest.url, operatorTokenPath: manifest.credentialFile, ownerEmail: s.auth.user(owner.ownerUserId).email, ownerPassword: password, ownerToken: tokens.get(owner.ownerUserId), ownerBotId: owner.id, ownerConversationId: owner.mainConversationId, nativeSessionKeys: { alice: manifest.alice, product: manifest.product }, managedProof: false }), { mode: 0o600 });
      console.log(JSON.stringify({ uiFixture: 'ready', privateState: statePath, shutdown: 'Send SIGTERM to the pid in the private state file.' }));
      try {
        const { promise, resolve } = Promise.withResolvers<void>();
        process.once('SIGTERM', resolve);
        process.once('SIGINT', resolve);
        await promise;
      } finally {
        realtime.close();
        await server.stop(true);
      }
    }
  } finally {
    s.addressedAgents.close();
    runtime.close();
    await s.integrations.dispose?.();
    s.lemon.close();
    store.close();
  }
}
