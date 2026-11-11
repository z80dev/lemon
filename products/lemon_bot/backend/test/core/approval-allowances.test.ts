import { describe, expect, test } from 'bun:test';
import { randomBytes } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { createMutationService } from '../../src/core/mutations';
import { createPrivateCodec } from '../../src/core/config';
import { installHelpers } from '../../src/core/helpers';
import { ApiError } from '../../src/core/errors';
import {
  TOOL_GROUPS,
  approvalToolGroup,
  botApprovalReview,
  botBindingDigest,
  chatOptionFor,
  createApprovalAllowanceRoutes,
  endApprovalAllowances,
  findConcurrentPendingApprovals,
  grantChatAllowance,
  matchApprovalAllowance,
  recordAllowanceUse,
} from '../../src/core/approval-allowances';

const owner: Principal = {
  kind: 'user',
  id: 'user_1',
  userId: 'user_1',
  workspaceId: 'ws_1',
  role: 'owner',
  sessionId: 'session_1',
  botId: null,
  deviceId: null,
};

const otherUser: Principal = {
  kind: 'user',
  id: 'user_2',
  userId: 'user_2',
  workspaceId: 'ws_1',
  role: 'member',
  sessionId: 'session_2',
  botId: null,
  deviceId: null,
};

function fixture() {
  const store = new Store(':memory:');
  const key = randomBytes(32);
  const codec = createPrivateCodec(key);

  const services = {
    store,
    ...codec,
    config: {
      publicUrl: 'http://127.0.0.1:4080',
      controlUrl: 'ws://127.0.0.1:4040/ws',
      dataDir: '/tmp',
      host: '127.0.0.1',
      port: 4080,
      operatorToken: 'tok',
      trustedOverlay: false,
      operator: { instanceId: 'inst_1', initialAdminUser: 'user_1', name: 'Lemon' },
    },
  } as unknown as BackendServices;

  installHelpers(services);
  services.mutations = createMutationService(services, key);

  const eventsList: { event: string; payload: unknown; audience: unknown }[] = [];
  services.events = {
    emit(event, payload, audience) {
      eventsList.push({ event, payload, audience });
      return { type: 'event', seq: String(eventsList.length), event, payload, timestampMs: services.now() } as P.RealtimeEvent;
    },
    cursor: () => String(eventsList.length),
    earliestCursor: () => '1',
    replay: () => [],
    visible: () => true,
    subscribe: () => () => {},
  };

  services.auth = {
    authenticate: async () => null,
    user: id => store.require<P.User>('users', id),
    member: userId => {
      const m = store.get<P.Member>('members', userId);
      if (m) return m;
      return {
        id: userId,
        userId,
        email: 'test@example.invalid',
        displayName: 'Member',
        role: userId === owner.userId ? 'owner' : 'member',
        enabled: true,
        revision: 1,
        createdAtMs: services.now(),
        updatedAtMs: services.now(),
      };
    },
    requireRole: () => {},
    bot: (_principal, botId) => store.require<P.Bot>('bots', botId),
    conversation: (principal, conversationId) => {
      const c = store.require<P.Conversation>('conversations', conversationId);
      if (c.ownerUserId !== principal.userId) throw new ApiError('not_found', 'Conversation not found.');
      return c;
    },
    machine: (_principal, machineId) => store.require<P.Machine>('machines', machineId),
    attachment: () => {
      throw new Error('unused');
    },
    canRead: () => true,
    revokeUser: async () => {},
    session: async () => {
      throw new Error('unused');
    },
    issueReauth: () => ({ reauthToken: 'tok', expiresAtMs: services.now() + 60000 }),
    consumeReauth: () => {},
  };

  const policy: P.EffectivePolicy = {
    userId: owner.userId,
    botId: 'bot_1',
    directoryGroupIds: [],
    productAccess: true,
    localExecutionCeiling: 'allow',
    workspaceReads: 'allow',
    allowSudo: false,
    allowEgress: true,
    rules: [],
    networkPolicies: [],
    explanations: [],
    rememberedApprovals: {
      chat: ['shell', 'files'],
      bot: ['shell', 'files'],
    },
  };

  services.integrations = {
    admission: async () => {},
    effectivePolicy: async () => policy,
    connectorConfig: async () => [],
    sendApprovedDraft: async () => ({ providerMessageId: null, runId: null }),
    emitProviderNotifications: async () => {},
    channelIngress: async () => {
      throw new Error('unused');
    },
    providerCapabilities: () => ({}),
  };

  store.put('users', { id: owner.userId, revision: 1, email: 'owner@example.invalid', displayName: 'Owner', createdAtMs: 1000, updatedAtMs: 1000 });
  store.put('users', { id: otherUser.userId, revision: 1, email: 'other@example.invalid', displayName: 'Other', createdAtMs: 1000, updatedAtMs: 1000 });
  store.put('members', { id: owner.userId, userId: owner.userId, email: 'owner@example.invalid', displayName: 'Owner', role: 'owner', enabled: true, revision: 1, createdAtMs: 1000, updatedAtMs: 1000 });
  store.put('members', { id: otherUser.userId, userId: otherUser.userId, email: 'other@example.invalid', displayName: 'Other', role: 'member', enabled: true, revision: 1, createdAtMs: 1000, updatedAtMs: 1000 });

  const machine: P.Machine = services.resource('machine', {
    nodeId: 'node_1',
    nodeName: 'node',
    name: 'MacMini',
    ownerUserId: owner.userId,
    accessUserIds: [],
    status: 'online',
    lastSeenAtMs: 1000,
    labels: {},
    botIds: ['bot_1'],
  });
  store.put('machines', machine);

  const bot: P.Bot = services.resource('bot', {
    ownerUserId: owner.userId,
    machineId: machine.id,
    profileId: 'profile_1',
    name: 'Botty',
    title: 'Assistant',
    job: 'Help',
    instructions: 'Be helpful',
    avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null },
    voice: { voiceId: 'default', speed: 1, language: null },
    language: null,
    skillIds: [],
    referenceAttachmentIds: [],
    mainConversationId: 'room_1',
    sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true },
    activity: 'idle',
    activeRunIds: [],
  });
  store.put('bots', bot);

  const room: P.Conversation = services.resource('conversation', {
    kind: 'dm',
    name: 'Chat',
    botIds: [bot.id],
    ownerUserId: owner.userId,
    parentConversationId: null,
    leadBotId: bot.id,
    channelBindingId: null,
    lastEntryId: null,
    unreadCount: 0,
    lastReadSeq: 0,
    activity: [],
  });
  store.put('conversations', room);

  store.setMetadata('governance', { rememberedApprovals: 'chat_and_bot', revision: 1 });
  store.setMetadata(`botPolicySync:${bot.id}`, { state: 'acknowledged', revision: 1 });
  store.setMetadata(`botPlacementEpoch:${bot.id}`, 1);

  return { services, store, owner, otherUser, bot, room, machine, policy, eventsList };
}

function context(services: BackendServices, user: Principal, method: string, path: string, body: unknown = {}, params: Record<string, string> = {}, query = new URLSearchParams()): RequestContext {
  const routes = createApprovalAllowanceRoutes(services);
  const route = routes.find(r => r.method === method && r.path === path) ?? {
    method,
    path,
    auth: 'member' as const,
    handler: () => {
      throw new Error(`Route not found: ${method} ${path}`);
    },
  };
  return {
    request: new Request(`http://127.0.0.1:4080${path}`, { method }),
    params,
    query,
    body,
    user,
    services,
    requestId: 'req_1',
    route,
    nonceResourceIds: [],
  };
}

describe('TOOL_GROUPS and approvalToolGroup', () => {
  test('correctly maps eligible runtime tools to their groups and categories', () => {
    expect(approvalToolGroup('bash')).toBe('terminal');
    expect(approvalToolGroup('bash_output')).toBe('terminal');
    expect(approvalToolGroup('kill_process')).toBe('terminal');
    expect(TOOL_GROUPS.terminal.category).toBe('shell');
    expect(TOOL_GROUPS.terminal.cardLabel).toBe('Allow Terminal for this chat');

    expect(approvalToolGroup('write')).toBe('file_changes');
    expect(approvalToolGroup('edit')).toBe('file_changes');
    expect(approvalToolGroup('patch')).toBe('file_changes');
    expect(approvalToolGroup('ast_grep')).toBe('file_changes');
    expect(approvalToolGroup('checkpoint')).toBe('file_changes');
    expect(TOOL_GROUPS.file_changes.category).toBe('files');
    expect(TOOL_GROUPS.file_changes.cardLabel).toBe('Allow file changes for this chat');

    expect(approvalToolGroup('read')).toBe('file_reading');
    expect(approvalToolGroup('ls')).toBe('file_reading');
    expect(approvalToolGroup('find')).toBe('file_reading');
    expect(approvalToolGroup('grep')).toBe('file_reading');
    expect(TOOL_GROUPS.file_reading.category).toBe('files');
    expect(TOOL_GROUPS.file_reading.cardLabel).toBe('Allow file reading for this chat');

    expect(approvalToolGroup('browser_click')).toBeNull();
    expect(approvalToolGroup('tool_invoke')).toBeNull();
    expect(approvalToolGroup('lsp_diagnostics')).toBeNull();
    expect(approvalToolGroup('propose_plan')).toBeNull();
    expect(approvalToolGroup(null)).toBeNull();
    expect(approvalToolGroup('')).toBeNull();
  });
});

describe('core eligibility: chatOptionFor', () => {
  test('returns option and context for eligible lemon_exec tool in owner_chat with interactive owner', async () => {
    const { services, store, owner, bot, room } = fixture();
    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    const result = await chatOptionFor(services, owner, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'bash',
      source: 'lemon_exec',
    });

    expect(result).not.toBeNull();
    expect(result!.option).toEqual({
      toolGroup: 'terminal',
      label: 'Allow Terminal for this chat',
    });
    expect(result!.context).toEqual({
      toolGroup: 'terminal',
      contextKey: 'ctx_key_123',
      origin: 'owner_chat',
    });
  });

  test('access requests never offer remembered allowances even with an eligible tool and context', async () => {
    const { services, store, owner, bot, room } = fixture();
    try {
      const run: P.Run = services.resource('run', {
        conversationId: room.id, botId: bot.id, initiatorUserId: owner.userId, clientNonce: 'access_nonce_00000001',
        status: 'running', error: null, startedAtMs: 1000, completedAtMs: null, routineRunId: null,
      });
      store.put('runs', run);
      store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
      store.setMetadata('runtimeInvocation:up_access', { invocationContextKey: 'eligible_context' });
      const input = { bot, run, upstreamRunId: 'up_access', tool: 'bash' };
      expect(await chatOptionFor(services, owner, { ...input, source: 'lemon_exec' })).not.toBeNull();
      expect(await chatOptionFor(services, owner, { ...input, source: 'access_request' })).toBeNull();
      expect(store.list('approvalAllowances')).toEqual([]);
    } finally { store.close(); }
  });

  test('refuses product-source, forceHuman, non-eligible tools, and non-interactive principal', async () => {
    const { services, store, owner, bot, room } = fixture();
    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    // 1. source: 'product'
    expect(await chatOptionFor(services, owner, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'bash',
      source: 'product',
    })).toBeNull();

    // 2. forceHuman: true
    expect(await chatOptionFor(services, owner, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'bash',
      source: 'lemon_exec',
      forceHuman: true,
    })).toBeNull();

    // 3. ineligible tool
    expect(await chatOptionFor(services, owner, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'browser_click',
      source: 'lemon_exec',
    })).toBeNull();

    // 4. non-interactive principal (sessionId: null)
    expect(await chatOptionFor(services, { ...owner, sessionId: null }, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'bash',
      source: 'lemon_exec',
    })).toBeNull();

    // 5. bot principal
    expect(await chatOptionFor(services, { kind: 'bot', id: 'bot_1', userId: owner.userId, workspaceId: 'ws_1', role: 'member', sessionId: null, botId: 'bot_1', deviceId: null }, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'bash',
      source: 'lemon_exec',
    })).toBeNull();

    // 6. non-owner
    expect(await chatOptionFor(services, otherUser, {
      bot,
      run,
      bound: { upstreamRunId: 'up_1' },
      tool: 'bash',
      source: 'lemon_exec',
    })).toBeNull();
  });

  test('refuses non-owner_chat origins, terminal runs, missing contextKey, and reviewMode every_time', async () => {
    const { services, store, owner, bot, room } = fixture();
    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    // 1. origin: routine
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'routine');
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // 2. origin: external
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'external');
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // 3. origin: native_followup
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'native_followup');
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // 4. Reset to owner_chat but run is terminal
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    const succeededRun = { ...run, status: 'succeeded' as const };
    expect(await chatOptionFor(services, owner, { bot, run: succeededRun, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // 5. Missing context key
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'non_existent_upstream' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // 6. Review mode: every_time
    store.setMetadata(`botApprovalReview:${bot.id}`, 'every_time');
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();
  });

  test('refuses when effective policy restricts category or ceiling is deny', async () => {
    const { services, store, owner, bot, room, policy } = fixture();
    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    // 1. localExecutionCeiling: deny
    policy.localExecutionCeiling = 'deny';
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // 2. shell category not in rememberedApprovals.chat
    policy.localExecutionCeiling = 'allow';
    policy.rememberedApprovals = { chat: ['files'], bot: ['files'] };
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'bash', source: 'lemon_exec' })).toBeNull();

    // files category still allowed
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'write', source: 'lemon_exec' })).not.toBeNull();

    // 3. effectivePolicy throwing fails closed to null
    services.integrations.effectivePolicy = async () => {
      throw new Error('policy unavailable');
    };
    expect(await chatOptionFor(services, owner, { bot, run, bound: { upstreamRunId: 'up_1' }, tool: 'write', source: 'lemon_exec' })).toBeNull();
  });
});

describe('matching and lazy invalidation: matchApprovalAllowance', () => {
  test('matches active chat allowance for owner_chat and lazy ends on contextKey mismatch', async () => {
    const { services, store, owner, bot, room } = fixture();
    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    // Grant chat allowance
    const allowance = await grantChatAllowance(services, owner, {
      botId: bot.id,
      conversationId: room.id,
      toolGroup: 'terminal',
      contextKey: 'ctx_key_123',
    });
    expect(allowance.state).toBe('active');
    expect(allowance.toolGroups).toEqual(['terminal']);

    // Match succeeds
    const matched = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash');
    expect(matched).not.toBeNull();
    expect(matched!.id).toBe(allowance.id);

    // Context key changes (lazy invalidation: permissions_changed)
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'different_context_key' });
    const matchFailed = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash');
    expect(matchFailed).toBeNull();

    const endedAllowance = store.require<P.ApprovalAllowance>('approvalAllowances', allowance.id);
    expect(endedAllowance.state).toBe('ended');
    expect(endedAllowance.endedReason).toBe('permissions_changed');
  });

  test('lazy ends chat allowance on policy change', async () => {
    const { services, store, owner, bot, room, policy } = fixture();
    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    const allowance = await grantChatAllowance(services, owner, {
      botId: bot.id,
      conversationId: room.id,
      toolGroup: 'terminal',
      contextKey: 'ctx_key_123',
    });

    // Remove shell from chat policy
    policy.rememberedApprovals = { chat: ['files'], bot: ['files'] };

    const matchFailed = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash');
    expect(matchFailed).toBeNull();

    const endedAllowance = store.require<P.ApprovalAllowance>('approvalAllowances', allowance.id);
    expect(endedAllowance.state).toBe('ended');
    expect(endedAllowance.endedReason).toBe('policy_changed');
  });

  test('matches bot-wide allowance for routine and owner_chat, but never external', async () => {
    const { services, store, owner, bot, room } = fixture();
    const bindingDigest = botBindingDigest(services, bot);

    const botAllowance: P.ApprovalAllowance = services.resource('allowance', {
      scope: 'bot',
      botId: bot.id,
      conversationId: null,
      ownerUserId: bot.ownerUserId,
      toolGroups: ['terminal', 'file_changes', 'file_reading'],
      label: "Doesn't ask for Terminal & Files",
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', botAllowance);
    store.setMetadata(`approvalAllowanceBinding:${botAllowance.id}`, { bindingDigest });

    expect(botApprovalReview(services, bot.id)).toBe('bot_wide');

    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_1',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'ctx_key_123' });

    // 1. Matches routine origin
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'routine');
    const matchedRoutine = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash');
    expect(matchedRoutine).not.toBeNull();
    expect(matchedRoutine!.id).toBe(botAllowance.id);

    // 2. Matches owner_chat origin
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    const matchedOwner = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'write');
    expect(matchedOwner).not.toBeNull();
    expect(matchedOwner!.id).toBe(botAllowance.id);

    // 3. Matches native_followup origin
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'native_followup');
    const matchedFollowup = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'read');
    expect(matchedFollowup).not.toBeNull();

    // 4. Never matches external origin
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'external');
    expect(await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash')).toBeNull();

    // 5. Never matches other origin
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'other');
    expect(await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash')).toBeNull();

    // 6. Bot move / placementEpoch bump causes bindingDigest mismatch -> lazy ends permissions_changed
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'routine');
    store.setMetadata(`botPlacementEpoch:${bot.id}`, 99); // bumped placement
    const matchMove = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash');
    expect(matchMove).toBeNull();

    const endedBotAllowance = store.require<P.ApprovalAllowance>('approvalAllowances', botAllowance.id);
    expect(endedBotAllowance.state).toBe('ended');
    expect(endedBotAllowance.endedReason).toBe('permissions_changed');
  });

  test('bot-wide takes priority and a stale chat allowance never revokes a valid bot-wide allowance', async () => {
    const { services, store, owner, bot, room } = fixture();
    const bindingDigest = botBindingDigest(services, bot);

    const botAllowance: P.ApprovalAllowance = services.resource('allowance', {
      scope: 'bot',
      botId: bot.id,
      conversationId: null,
      ownerUserId: bot.ownerUserId,
      toolGroups: ['terminal', 'file_changes', 'file_reading'],
      label: "Doesn't ask for Terminal & Files",
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', botAllowance);
    store.setMetadata(`approvalAllowanceBinding:${botAllowance.id}`, { bindingDigest });

    // A stale chat allowance bound to an outdated context key coexists with the bot-wide allowance.
    const chatAllowance: P.ApprovalAllowance = services.resource('allowance', {
      scope: 'chat',
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal'],
      label: 'Terminal allowed in this chat',
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', chatAllowance);
    store.setMetadata(`approvalAllowanceBinding:${chatAllowance.id}`, { contextKey: 'stale_context_key' });

    const run: P.Run = services.resource('run', {
      conversationId: room.id,
      botId: bot.id,
      initiatorUserId: owner.userId,
      clientNonce: 'nonce_coexist',
      status: 'running',
      error: null,
      startedAtMs: 1000,
      completedAtMs: null,
      routineRunId: null,
    });
    store.put('runs', run);
    store.setMetadata(`runApprovalOrigin:${run.id}`, 'owner_chat');
    store.setMetadata('runtimeInvocation:up_1', { invocationContextKey: 'current_context_key' });

    // Review mode is bot_wide because an active bot allowance exists.
    expect(botApprovalReview(services, bot.id)).toBe('bot_wide');

    // Bot-wide is prioritized, so the match returns the bot allowance and never ends it.
    const matched = await matchApprovalAllowance(services, owner, run, { upstreamRunId: 'up_1' }, 'bash');
    expect(matched).not.toBeNull();
    expect(matched!.id).toBe(botAllowance.id);
    expect(store.require<P.ApprovalAllowance>('approvalAllowances', botAllowance.id).state).toBe('active');

    // The stale chat allowance is untouched by a successful bot-wide match.
    expect(store.require<P.ApprovalAllowance>('approvalAllowances', chatAllowance.id).state).toBe('active');
  });

  test('confirming a bot-wide allowance ends existing chat allowances for the Bot', async () => {
    const { services, store, owner, bot, room } = fixture();

    const chatAllowance = await grantChatAllowance(services, owner, {
      botId: bot.id,
      conversationId: room.id,
      toolGroup: 'terminal',
      contextKey: 'current_context_key',
    });
    expect(chatAllowance.state).toBe('active');

    const routes = createApprovalAllowanceRoutes(services);
    const previewRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/bots/:id/approval-allowances/preview')!;
    const confirmRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/bots/:id/approval-allowances')!;

    const preview = (await previewRoute.handler(
      context(services, owner, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_coex_001' }, { id: bot.id })
    )) as P.Confirmation;

    const confirmed = (await confirmRoute.handler(
      context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_coex_002', confirmationToken: preview.confirmationToken, confirmName: bot.name, revision: bot.revision }, { id: bot.id })
    )) as P.ApprovalAllowance;

    expect(confirmed.scope).toBe('bot');
    expect(confirmed.state).toBe('active');

    const endedChat = store.require<P.ApprovalAllowance>('approvalAllowances', chatAllowance.id);
    expect(endedChat.state).toBe('ended');
    expect(endedChat.endedReason).toBe('review_mode_changed');
  });
});

describe('grant, record use, concurrent approvals and eager end', () => {
  test('grantChatAllowance upserts multi-group and recordAllowanceUse audits on bot-scope', async () => {
    const { services, store, owner, bot, room } = fixture();

    // First grant: terminal
    const a1 = await grantChatAllowance(services, owner, {
      botId: bot.id,
      conversationId: room.id,
      toolGroup: 'terminal',
      contextKey: 'key_1',
    });
    expect(a1.toolGroups).toEqual(['terminal']);
    expect(a1.label).toBe('Terminal allowed in this chat');

    // Second grant on same context: file_changes
    const a2 = await grantChatAllowance(services, owner, {
      botId: bot.id,
      conversationId: room.id,
      toolGroup: 'file_changes',
      contextKey: 'key_1',
    });
    expect(a2.id).toBe(a1.id);
    expect(a2.toolGroups).toEqual(['terminal', 'file_changes']);
    expect(a2.revision).toBe(2);

    // recordAllowanceUse on chat scope increments useCount and updates lastUsedAtMs
    const usedChat = await recordAllowanceUse(services, owner, a2, { tool: 'bash', runId: 'run_1', origin: 'owner_chat' });
    expect(usedChat.useCount).toBe(1);
    expect(usedChat.lastUsedAtMs).toBe(services.now());

    // Bot scope allowance audits use
    const botAllowance: P.ApprovalAllowance = services.resource('allowance', {
      scope: 'bot',
      botId: bot.id,
      conversationId: null,
      ownerUserId: bot.ownerUserId,
      toolGroups: ['terminal'],
      label: "Doesn't ask for Terminal & Files",
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', botAllowance);

    await recordAllowanceUse(services, owner, botAllowance, { tool: 'bash', runId: 'run_1', origin: 'routine' });
    const audits = store.list<P.AuditRecord>('auditRecords', a => a.action === 'approval_allowance.use');
    expect(audits).toHaveLength(1);
    expect(audits[0]!.outcome).toBe('succeeded');
    expect(audits[0]!.metadata).toEqual({ tool: 'bash', runId: 'run_1', origin: 'routine' });
  });

  test('findConcurrentPendingApprovals finds matching lemon_exec pending cards in conversation', () => {
    const { services, store, owner, bot, room } = fixture();

    const gate1: P.Gate = { id: 'gate_1', revision: 1, state: 'pending', targetUserId: owner.userId, expiresAtMs: 200000, resolvedAtMs: null, resolvedByUserId: null };
    const app1: P.Approval = services.resource('approval', {
      gate: gate1,
      entryId: 'entry_1',
      conversationId: room.id,
      botId: bot.id,
      runId: 'run_1',
      source: 'lemon_exec',
      category: 'shell',
      title: 'Bash',
      description: 'Run cmd',
      target: 'host',
      inputs: {},
      policyMode: 'ask_first',
      review: 'not_run',
      ruleId: null,
      scope: { kind: 'once', label: 'once', machineId: 'm1', machineLabel: 'Mac', botId: bot.id, runId: 'run_1', origin: null, connectorId: null, consequences: [], expiresAtMs: 200000 },
    });
    store.put('approvals', app1);
    store.setMetadata(`approvalAllowanceContext:${app1.id}`, { toolGroup: 'terminal', contextKey: 'key_1', origin: 'owner_chat' });

    const gate2: P.Gate = { id: 'gate_2', revision: 1, state: 'pending', targetUserId: owner.userId, expiresAtMs: 200000, resolvedAtMs: null, resolvedByUserId: null };
    const app2: P.Approval = services.resource('approval', {
      gate: gate2,
      entryId: 'entry_2',
      conversationId: room.id,
      botId: bot.id,
      runId: 'run_1',
      source: 'lemon_exec',
      category: 'shell',
      title: 'Bash 2',
      description: 'Run cmd 2',
      target: 'host',
      inputs: {},
      policyMode: 'ask_first',
      review: 'not_run',
      ruleId: null,
      scope: { kind: 'once', label: 'once', machineId: 'm1', machineLabel: 'Mac', botId: bot.id, runId: 'run_1', origin: null, connectorId: null, consequences: [], expiresAtMs: 200000 },
    });
    store.put('approvals', app2);
    store.setMetadata(`approvalAllowanceContext:${app2.id}`, { toolGroup: 'terminal', contextKey: 'key_1', origin: 'owner_chat' });

    const concurrent = findConcurrentPendingApprovals(services, {
      conversationId: room.id,
      botId: bot.id,
      toolGroup: 'terminal',
      contextKey: 'key_1',
      excludeApprovalId: app1.id,
    });

    expect(concurrent).toHaveLength(1);
    expect(concurrent[0]!.id).toBe(app2.id);
  });

  test('endApprovalAllowances ends matching allowances by filter and writes audit', () => {
    const { services, store, owner, bot, room } = fixture();
    const a1 = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Terminal',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', a1);

    const ended = endApprovalAllowances(services, owner, { botId: bot.id, scope: 'chat' }, 'policy_changed');
    expect(ended).toHaveLength(1);
    expect(ended[0]!.id).toBe(a1.id);
    expect(ended[0]!.state).toBe('ended');
    expect(ended[0]!.endedReason).toBe('policy_changed');

    const audit = store.list<P.AuditRecord>('auditRecords', a => a.action === 'approval_allowance.end');
    expect(audit).toHaveLength(1);
    expect(audit[0]!.outcome).toBe('succeeded');
  });
});

describe('routes: conversations and bots lists', () => {
  test('GET /v1/conversations/:id/approval-allowances filters by active/ended', async () => {
    const { services, store, owner, bot, room } = fixture();
    const a1 = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Terminal',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    const a2 = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['file_changes' as const],
      label: 'Files',
      state: 'ended' as const,
      endedReason: 'stopped' as const,
      endedAtMs: 2000,
      endedByUserId: owner.userId,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', a1);
    store.put('approvalAllowances', a2);

    const routes = createApprovalAllowanceRoutes(services);
    const getRoute = routes.find(r => r.method === 'GET' && r.path === '/v1/conversations/:id/approval-allowances')!;

    // 1. All allowances in conversation
    const resAll = (await getRoute.handler(context(services, owner, 'GET', '/v1/conversations/:id/approval-allowances', {}, { id: room.id }))) as P.Page<P.ApprovalAllowance>;
    expect(resAll.items).toHaveLength(2);

    // 2. Filter active
    const qActive = new URLSearchParams({ state: 'active' });
    const resActive = (await getRoute.handler(context(services, owner, 'GET', '/v1/conversations/:id/approval-allowances', {}, { id: room.id }, qActive))) as P.Page<P.ApprovalAllowance>;
    expect(resActive.items).toHaveLength(1);
    expect(resActive.items[0]!.id).toBe(a1.id);

    // 3. Filter ended
    const qEnded = new URLSearchParams({ state: 'ended' });
    const resEnded = (await getRoute.handler(context(services, owner, 'GET', '/v1/conversations/:id/approval-allowances', {}, { id: room.id }, qEnded))) as P.Page<P.ApprovalAllowance>;
    expect(resEnded.items).toHaveLength(1);
    expect(resEnded.items[0]!.id).toBe(a2.id);
  });

  test('GET /v1/bots/:id/approval-allowances lists allowances for bot', async () => {
    const { services, store, owner, bot, room } = fixture();
    const a1 = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Terminal',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', a1);

    const routes = createApprovalAllowanceRoutes(services);
    const getRoute = routes.find(r => r.method === 'GET' && r.path === '/v1/bots/:id/approval-allowances')!;
    const res = (await getRoute.handler(context(services, owner, 'GET', '/v1/bots/:id/approval-allowances', {}, { id: bot.id }))) as P.Page<P.ApprovalAllowance>;
    expect(res.items).toHaveLength(1);
    expect(res.items[0]!.id).toBe(a1.id);
  });
});

describe('routes: stop, review mode, and bot-wide preview/confirm', () => {
  test('POST /v1/approval-allowances/:id/stop stops active allowance and enforces revision and ownership', async () => {
    const { services, store, owner, otherUser, bot, room } = fixture();
    const a1 = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Terminal',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', a1);

    const routes = createApprovalAllowanceRoutes(services);
    const stopRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/approval-allowances/:id/stop')!;

    // 1. Non-owner cannot stop
    await expect(
      stopRoute.handler(context(services, otherUser, 'POST', '/v1/approval-allowances/:id/stop', { clientNonce: 'client_nonce_stop_001', revision: 1 }, { id: a1.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // 2. Revision conflict with stale revision
    await expect(
      stopRoute.handler(context(services, owner, 'POST', '/v1/approval-allowances/:id/stop', { clientNonce: 'client_nonce_stop_002', revision: 99 }, { id: a1.id }))
    ).rejects.toMatchObject({ code: 'revision_conflict' });

    // 3. Successful stop
    const stopped = (await stopRoute.handler(
      context(services, owner, 'POST', '/v1/approval-allowances/:id/stop', { clientNonce: 'client_nonce_stop_003', revision: 1 }, { id: a1.id })
    )) as P.ApprovalAllowance;
    expect(stopped.state).toBe('ended');
    expect(stopped.endedReason).toBe('stopped');
    expect(stopped.endedByUserId).toBe(owner.userId);

    // 4. Same nonce replays exactly and returns the receipt
    const replayed = (await stopRoute.handler(
      context(services, owner, 'POST', '/v1/approval-allowances/:id/stop', { clientNonce: 'client_nonce_stop_003', revision: 1 }, { id: a1.id })
    )) as P.ApprovalAllowance;
    expect(replayed.id).toBe(stopped.id);
    expect(replayed.state).toBe('ended');

    // 5. Different nonce with now-stale revision gets revision_conflict
    await expect(
      stopRoute.handler(context(services, owner, 'POST', '/v1/approval-allowances/:id/stop', { clientNonce: 'client_nonce_stop_004', revision: 1 }, { id: a1.id }))
    ).rejects.toMatchObject({ code: 'revision_conflict' });

    const audit = store.list<P.AuditRecord>('auditRecords', a => a.action === 'approval_allowance.stop');
    expect(audit).toHaveLength(1);
    expect(audit[0]!.outcome).toBe('succeeded');
  });

  test('PATCH /v1/bots/:id/approval-review updates review mode and ends allowances accordingly', async () => {
    const { services, store, owner, otherUser, bot, room } = fixture();
    const chatAllowance = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Terminal',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    const botAllowance = services.resource('allowance', {
      scope: 'bot' as const,
      botId: bot.id,
      conversationId: null,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Bot-wide',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', chatAllowance);
    store.put('approvalAllowances', botAllowance);

    const routes = createApprovalAllowanceRoutes(services);
    const reviewRoute = routes.find(r => r.method === 'PATCH' && r.path === '/v1/bots/:id/approval-review')!;

    // Non-owner cannot change
    await expect(
      reviewRoute.handler(context(services, otherUser, 'PATCH', '/v1/bots/:id/approval-review', { clientNonce: 'client_nonce_review_01', revision: 1, mode: 'per_chat' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // Choosing every_time ends BOTH bot and chat allowances
    const updated = (await reviewRoute.handler(
      context(services, owner, 'PATCH', '/v1/bots/:id/approval-review', { clientNonce: 'client_nonce_review_02', revision: 1, mode: 'every_time' }, { id: bot.id })
    )) as P.Bot;
    expect(updated.revision).toBe(2);

    expect(store.require<P.ApprovalAllowance>('approvalAllowances', chatAllowance.id).state).toBe('ended');
    expect(store.require<P.ApprovalAllowance>('approvalAllowances', botAllowance.id).state).toBe('ended');
    expect(botApprovalReview(services, bot.id)).toBe('every_time');
  });

  test('bot-wide preview and confirm creates scope:bot allowance, refused on missing requirements', async () => {
    const { services, store, owner, otherUser, bot } = fixture();

    const routes = createApprovalAllowanceRoutes(services);
    const previewRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/bots/:id/approval-allowances/preview')!;
    const confirmRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/bots/:id/approval-allowances')!;

    // 1. Refused for non-owner
    await expect(
      previewRoute.handler(context(services, otherUser, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_001' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // 2. Refused for non-interactive user (sessionId: null)
    await expect(
      previewRoute.handler(context(services, { ...owner, sessionId: null }, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_002' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // 3. Refused when governance is not chat_and_bot
    store.setMetadata('governance', { rememberedApprovals: 'chat', revision: 1 });
    await expect(
      previewRoute.handler(context(services, owner, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_003' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'policy_denied' });

    // Restore governance chat_and_bot
    store.setMetadata('governance', { rememberedApprovals: 'chat_and_bot', revision: 1 });

    // 4. Successful preview
    const preview = (await previewRoute.handler(
      context(services, owner, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_004' }, { id: bot.id })
    )) as P.Confirmation;
    expect(preview.confirmName).toBe(bot.name);
    expect(preview.effects[0]).toContain('Lemon will run any command and change any file as you on MacMini without asking');

    // 5. Confirm with invalid/expired token fails
    await expect(
      confirmRoute.handler(context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_conf_001', confirmationToken: 'wrong_token_12345678', confirmName: bot.name, revision: bot.revision }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'confirmation_required' });

    // 6. Confirm succeeds
    const confirmed = (await confirmRoute.handler(
      context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_conf_002', confirmationToken: preview.confirmationToken, confirmName: bot.name, revision: bot.revision }, { id: bot.id })
    )) as P.ApprovalAllowance;

    expect(confirmed.scope).toBe('bot');
    expect(confirmed.state).toBe('active');
    expect(confirmed.toolGroups).toEqual(['terminal', 'file_changes', 'file_reading']);
    expect(confirmed.label).toBe("Doesn't ask for Terminal & Files");
    expect(botApprovalReview(services, bot.id)).toBe('bot_wide');

    // Reusing confirmation token fails
    await expect(
      confirmRoute.handler(context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_conf_003', confirmationToken: preview.confirmationToken, confirmName: bot.name, revision: bot.revision }, { id: bot.id }))
    ).rejects.toThrow();

    store.close();
  });
  test('PATCH /v1/bots/:id/approval-review updates review mode and ends allowances accordingly', async () => {
    const { services, store, owner, otherUser, bot, room } = fixture();
    const chatAllowance = services.resource('allowance', {
      scope: 'chat' as const,
      botId: bot.id,
      conversationId: room.id,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Terminal',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    const botAllowance = services.resource('allowance', {
      scope: 'bot' as const,
      botId: bot.id,
      conversationId: null,
      ownerUserId: owner.userId,
      toolGroups: ['terminal' as const],
      label: 'Bot-wide',
      state: 'active' as const,
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: owner.userId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    store.put('approvalAllowances', chatAllowance);
    store.put('approvalAllowances', botAllowance);

    const routes = createApprovalAllowanceRoutes(services);
    const reviewRoute = routes.find(r => r.method === 'PATCH' && r.path === '/v1/bots/:id/approval-review')!;

    // Non-owner cannot change
    await expect(
      reviewRoute.handler(context(services, otherUser, 'PATCH', '/v1/bots/:id/approval-review', { clientNonce: 'client_nonce_review_01', revision: 1, mode: 'per_chat' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // Choosing every_time ends BOTH bot and chat allowances
    const updated = (await reviewRoute.handler(
      context(services, owner, 'PATCH', '/v1/bots/:id/approval-review', { clientNonce: 'client_nonce_review_01', revision: 1, mode: 'every_time' }, { id: bot.id })
    )) as P.Bot;
    expect(updated.revision).toBe(2);

    expect(store.require<P.ApprovalAllowance>('approvalAllowances', chatAllowance.id).state).toBe('ended');
    expect(store.require<P.ApprovalAllowance>('approvalAllowances', botAllowance.id).state).toBe('ended');
    expect(botApprovalReview(services, bot.id)).toBe('every_time');
  });

  test('bot-wide preview and confirm creates scope:bot allowance, refused on missing requirements', async () => {
    const { services, store, owner, otherUser, bot } = fixture();

    const routes = createApprovalAllowanceRoutes(services);
    const previewRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/bots/:id/approval-allowances/preview')!;
    const confirmRoute = routes.find(r => r.method === 'POST' && r.path === '/v1/bots/:id/approval-allowances')!;

    // 1. Refused for non-owner
    await expect(
      previewRoute.handler(context(services, otherUser, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_001' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // 2. Refused for non-interactive user (sessionId: null)
    await expect(
      previewRoute.handler(context(services, { ...owner, sessionId: null }, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_001' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'forbidden' });

    // 3. Refused when governance is not chat_and_bot
    store.setMetadata('governance', { rememberedApprovals: 'chat', revision: 1 });
    await expect(
      previewRoute.handler(context(services, owner, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_001' }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'policy_denied' });

    // Restore governance chat_and_bot
    store.setMetadata('governance', { rememberedApprovals: 'chat_and_bot', revision: 1 });

    // 4. Successful preview
    const preview = (await previewRoute.handler(
      context(services, owner, 'POST', '/v1/bots/:id/approval-allowances/preview', { clientNonce: 'client_nonce_prev_001' }, { id: bot.id })
    )) as P.Confirmation;
    expect(preview.confirmName).toBe(bot.name);
    expect(preview.effects[0]).toContain('Lemon will run any command and change any file as you on MacMini without asking');

    // 5. Confirm with invalid/expired token fails
    await expect(
      confirmRoute.handler(context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_conf_001', confirmationToken: 'wrong_token_value_001', confirmName: bot.name, revision: bot.revision }, { id: bot.id }))
    ).rejects.toMatchObject({ code: 'confirmation_required' });

    // 6. Confirm succeeds
    const confirmed = (await confirmRoute.handler(
      context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_conf_001', confirmationToken: preview.confirmationToken, confirmName: bot.name, revision: bot.revision }, { id: bot.id })
    )) as P.ApprovalAllowance;

    expect(confirmed.scope).toBe('bot');
    expect(confirmed.state).toBe('active');
    expect(confirmed.toolGroups).toEqual(['terminal', 'file_changes', 'file_reading']);
    expect(confirmed.label).toBe("Doesn't ask for Terminal & Files");
    expect(botApprovalReview(services, bot.id)).toBe('bot_wide');

    // Reusing confirmation token fails
    await expect(
      confirmRoute.handler(context(services, owner, 'POST', '/v1/bots/:id/approval-allowances', { clientNonce: 'client_nonce_conf_002', confirmationToken: preview.confirmationToken, confirmName: bot.name, revision: bot.revision }, { id: bot.id }))
    ).rejects.toThrow();

    store.close();
  });
});
