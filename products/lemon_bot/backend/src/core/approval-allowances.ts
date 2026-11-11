import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { z, parse, id, mutation, update, confirm, boundedText, queryObject } from './validation';

function principal(user: Principal | null): Principal {
  if (!user) fail('unauthenticated', 'Authentication required.');
  return user;
}

export const TOOL_GROUPS = {
  terminal: {
    tools: ['bash', 'bash_output', 'kill_process'],
    category: 'shell',
    cardLabel: 'Allow Terminal for this chat',
    chipLabel: 'Terminal allowed in this chat',
  },
  file_changes: {
    tools: ['write', 'edit', 'patch', 'ast_grep', 'checkpoint'],
    category: 'files',
    cardLabel: 'Allow file changes for this chat',
    chipLabel: 'File changes allowed in this chat',
  },
  file_reading: {
    tools: ['read', 'ls', 'find', 'grep'],
    category: 'files',
    cardLabel: 'Allow file reading for this chat',
    chipLabel: 'File reading allowed in this chat',
  },
} as const satisfies Record<P.ApprovalToolGroup, {
  tools: readonly string[];
  category: P.ActionCategory;
  cardLabel: string;
  chipLabel: string;
}>;

export function approvalToolGroup(tool: string | null | undefined): P.ApprovalToolGroup | null {
  if (!tool) return null;
  for (const [group, config] of Object.entries(TOOL_GROUPS) as [P.ApprovalToolGroup, typeof TOOL_GROUPS[P.ApprovalToolGroup]][]) {
    if ((config.tools as readonly string[]).includes(tool)) return group;
  }
  return null;
}

function runOrigin(services: BackendServices, runId: string | null | undefined): string {
  if (!runId) return 'other';
  return services.store.metadata<string>(`runApprovalOrigin:${runId}`) ?? 'other';
}

function runContextKey(services: BackendServices, upstreamRunId: string | null | undefined): string | null {
  if (!upstreamRunId) return null;
  const inv = services.store.metadata<{ invocationContextKey?: string }>(`runtimeInvocation:${upstreamRunId}`);
  return inv?.invocationContextKey ?? null;
}

export function botApprovalReview(services: BackendServices, botId: string): P.ApprovalReviewMode {
  const activeBotAllowance = services.store.list<P.ApprovalAllowance>(
    'approvalAllowances',
    item => item.botId === botId && item.scope === 'bot' && item.state === 'active'
  )[0];
  if (activeBotAllowance) return 'bot_wide';
  return services.store.metadata<P.ApprovalReviewMode>(`botApprovalReview:${botId}`) ?? 'per_chat';
}

export function botBindingDigest(services: BackendServices, bot: P.Bot): string {
  const botPolicySync = services.store.metadata(`botPolicySync:${bot.id}`);
  const placementEpoch = services.store.metadata<number>(`botPlacementEpoch:${bot.id}`) ?? 0;
  const ownerMember = services.store.get<P.Member>('members', bot.ownerUserId);
  const ownerRole = ownerMember?.role ?? 'member';
  return services.mutations.digest({ botPolicySync, placementEpoch, ownerRole });
}

function chatAllowanceLabel(groups: P.ApprovalToolGroup[]): string {
  if (groups.length === 1) return TOOL_GROUPS[groups[0]!].chipLabel;
  const names = groups.map(g => {
    if (g === 'terminal') return 'Terminal';
    if (g === 'file_changes') return 'File changes';
    if (g === 'file_reading') return 'File reading';
    return g;
  });
  return `${names.join(', ')} allowed in this chat`;
}

export interface ChatOptionInput {
  bot: P.Bot;
  run?: P.Run | null;
  runId?: string | null;
  bound?: { upstreamRunId: string } | null;
  upstreamRunId?: string | null;
  tool?: string | null;
  source?: string | null;
  forceHuman?: boolean | null;
}

export async function chatOptionFor(
  services: BackendServices,
  principal: Principal,
  input: ChatOptionInput
): Promise<{
  option: P.ApprovalChatOption;
  context: { toolGroup: P.ApprovalToolGroup; contextKey: string; origin: string };
} | null> {
  // Access consent changes a Bot grant; it never approves commands or remembered execution.
  if (input.source === 'access_request') return null;
  if (input.source !== 'lemon_exec') return null;
  if (input.forceHuman === true) return null;
  const group = approvalToolGroup(input.tool);
  if (!group) return null;

  if (principal.kind !== 'user' || principal.id !== principal.userId || principal.sessionId === null) return null;
  if (principal.userId !== input.bot.ownerUserId) return null;

  const run = input.run ?? (input.runId ? services.store.get<P.Run>('runs', input.runId) : null);
  if (!run) return null;
  if (['succeeded', 'failed', 'cancelled', 'outcome_unknown'].includes(run.status)) return null;

  const origin = runOrigin(services, run.id);
  if (origin !== 'owner_chat') return null;

  const reviewMode = botApprovalReview(services, input.bot.id);
  if (reviewMode !== 'per_chat') return null;

  const upstreamRunId = input.bound?.upstreamRunId ?? input.upstreamRunId;
  const contextKey = runContextKey(services, upstreamRunId);
  if (!contextKey) return null;

  try {
    const effective = await services.integrations.effectivePolicy(principal, input.bot.id);
    const category = TOOL_GROUPS[group].category;
    if (!effective.productAccess || (effective.localExecutionCeiling as string) === 'deny') return null;
    if (!effective.rememberedApprovals?.chat?.includes(category)) return null;
  } catch {
    return null;
  }

  return {
    option: {
      toolGroup: group,
      label: TOOL_GROUPS[group].cardLabel,
    },
    context: {
      toolGroup: group,
      contextKey,
      origin: 'owner_chat',
    },
  };
}

export async function grantChatAllowance(
  services: BackendServices,
  principal: Principal,
  input: {
    botId: string;
    conversationId: string;
    toolGroup: P.ApprovalToolGroup;
    contextKey: string;
    sourceApprovalId?: string | null;
  }
): Promise<P.ApprovalAllowance> {
  const existing = services.store.list<P.ApprovalAllowance>(
    'approvalAllowances',
    item => item.scope === 'chat' && item.state === 'active' && item.botId === input.botId && item.conversationId === input.conversationId
  ).find(item => {
    const binding = services.store.metadata<{ contextKey: string }>(`approvalAllowanceBinding:${item.id}`);
    return binding?.contextKey === input.contextKey;
  });

  if (existing) {
    const toolGroups = Array.from(new Set([...existing.toolGroups, input.toolGroup]));
    const updated = services.update(existing, {
      toolGroups,
      label: chatAllowanceLabel(toolGroups),
      sourceApprovalId: input.sourceApprovalId ?? existing.sourceApprovalId,
    });
    services.store.put('approvalAllowances', updated);
    services.events.emit('approval_allowance.upserted', updated, { userIds: [updated.ownerUserId] });
    services.audit(principal, 'approval_allowance.create', updated.id, 'succeeded', {
      scope: updated.scope,
      toolGroups: updated.toolGroups,
      botId: updated.botId,
      conversationId: updated.conversationId,
    });
    return updated;
  }

  const bot = services.store.require<P.Bot>('bots', input.botId);
  const allowance = services.resource('allowance', {
    scope: 'chat' as const,
    botId: input.botId,
    conversationId: input.conversationId,
    ownerUserId: bot.ownerUserId,
    toolGroups: [input.toolGroup],
    label: chatAllowanceLabel([input.toolGroup]),
    state: 'active' as const,
    endedReason: null,
    endedAtMs: null,
    endedByUserId: null,
    sourceApprovalId: input.sourceApprovalId ?? null,
    createdByUserId: principal.userId,
    useCount: 0,
    lastUsedAtMs: null,
  });
  services.store.put('approvalAllowances', allowance);
  services.store.setMetadata(`approvalAllowanceBinding:${allowance.id}`, { contextKey: input.contextKey });
  services.events.emit('approval_allowance.upserted', allowance, { userIds: [allowance.ownerUserId] });
  services.audit(principal, 'approval_allowance.create', allowance.id, 'succeeded', {
    scope: allowance.scope,
    toolGroups: allowance.toolGroups,
    botId: allowance.botId,
    conversationId: allowance.conversationId,
  });
  return allowance;
}

export function findConcurrentPendingApprovals(
  services: BackendServices,
  options: {
    conversationId: string;
    botId: string;
    toolGroup: P.ApprovalToolGroup;
    contextKey: string;
    excludeApprovalId?: string;
  }
): P.Approval[] {
  return services.store.list<P.Approval>('approvals', approval => {
    if (approval.id === options.excludeApprovalId) return false;
    if (approval.conversationId !== options.conversationId || approval.botId !== options.botId) return false;
    if (approval.source !== 'lemon_exec' || approval.gate.state !== 'pending') return false;
    const ctx = services.store.metadata<{ toolGroup: P.ApprovalToolGroup; contextKey: string; origin: string }>(
      `approvalAllowanceContext:${approval.id}`
    );
    return ctx !== null && ctx.toolGroup === options.toolGroup && ctx.contextKey === options.contextKey && ctx.origin === 'owner_chat';
  });
}

export async function matchApprovalAllowance(
  services: BackendServices,
  principal: Principal,
  run: P.Run,
  bound: { upstreamRunId: string; sessionKey?: string; nodeId?: string },
  tool: string
): Promise<P.ApprovalAllowance | null> {
  const group = approvalToolGroup(tool);
  if (!group) return null;

  const origin = runOrigin(services, run.id);
  if (origin === 'external' || origin === 'other') return null;

  const bot = services.store.get<P.Bot>('bots', run.botId);
  if (!bot) return null;
  if (['succeeded', 'failed', 'cancelled', 'outcome_unknown'].includes(run.status)) return null;

  const currentContextKey = runContextKey(services, bound.upstreamRunId);
  if (!currentContextKey) return null;
  // 1. Try matching bot-wide allowance first (prioritized; covers owner_chat, routine, native_followup)
  if (['owner_chat', 'routine', 'native_followup'].includes(origin)) {
    const botAllowances = services.store.list<P.ApprovalAllowance>(
      'approvalAllowances',
      a =>
        a.scope === 'bot' &&
        a.state === 'active' &&
        a.botId === bot.id &&
        a.ownerUserId === bot.ownerUserId &&
        a.toolGroups.includes(group)
    );

    if (botAllowances.length > 0) {
      const allowance = botAllowances[0]!;
      const expectedDigest = botBindingDigest(services, bot);
      const binding = services.store.metadata<{ bindingDigest: string }>(`approvalAllowanceBinding:${allowance.id}`);
      if (!binding || binding.bindingDigest !== expectedDigest) {
        endApprovalAllowances(services, null, { botId: bot.id, scope: 'bot' }, 'permissions_changed');
      } else {
        try {
          const effective = await services.integrations.effectivePolicy(principal, bot.id);
          const category = TOOL_GROUPS[group].category;
          if (!effective.productAccess || (effective.localExecutionCeiling as string) === 'deny' || !effective.rememberedApprovals?.bot?.includes(category)) {
            endApprovalAllowances(services, null, { botId: bot.id, scope: 'bot' }, 'policy_changed');
          } else {
            return allowance;
          }
        } catch {
          return null;
        }
      }
    }
  }

  // 2. Try matching chat allowance (only for owner_chat origin)
  if (origin === 'owner_chat') {
    const chatAllowances = services.store.list<P.ApprovalAllowance>(
      'approvalAllowances',
      a =>
        a.scope === 'chat' &&
        a.state === 'active' &&
        a.botId === bot.id &&
        a.conversationId === run.conversationId &&
        a.ownerUserId === run.initiatorUserId &&
        a.toolGroups.includes(group)
    );

    if (chatAllowances.length > 0) {
      const allowance = chatAllowances[0]!;
      const reviewMode = botApprovalReview(services, bot.id);
      if (reviewMode === 'every_time') {
        endApprovalAllowances(services, null, { botId: bot.id, scope: 'chat' }, 'review_mode_changed');
        return null;
      }

      const binding = services.store.metadata<{ contextKey: string }>(`approvalAllowanceBinding:${allowance.id}`);
      if (!binding || binding.contextKey !== currentContextKey) {
        endApprovalAllowances(services, null, { botId: bot.id, conversationId: allowance.conversationId ?? undefined, scope: 'chat' }, 'permissions_changed');
        return null;
      }

      try {
        const effective = await services.integrations.effectivePolicy(principal, bot.id);
        const category = TOOL_GROUPS[group].category;
        if (!effective.productAccess || (effective.localExecutionCeiling as string) === 'deny' || !effective.rememberedApprovals?.chat?.includes(category)) {
          endApprovalAllowances(services, null, { botId: bot.id, conversationId: allowance.conversationId ?? undefined, scope: 'chat' }, 'policy_changed');
          return null;
        }
      } catch {
        return null;
      }

      return allowance;
    }
  }

  return null;
}

export async function recordAllowanceUse(
  services: BackendServices,
  principal: Principal,
  allowance: P.ApprovalAllowance,
  details: { tool: string; runId: string; origin: string }
): Promise<P.ApprovalAllowance> {
  const current = services.store.get<P.ApprovalAllowance>('approvalAllowances', allowance.id) ?? allowance;
  const updated = services.update(current, {
    useCount: current.useCount + 1,
    lastUsedAtMs: services.now(),
  });
  services.store.put('approvalAllowances', updated);
  services.events.emit('approval_allowance.upserted', updated, { userIds: [updated.ownerUserId] });
  if (updated.scope === 'bot') {
    services.audit(principal, 'approval_allowance.use', updated.id, 'succeeded', {
      tool: details.tool,
      runId: details.runId,
      origin: details.origin,
    });
  }
  return updated;
}

export function endApprovalAllowances(
  services: BackendServices,
  actor: Principal | null,
  filter: {
    botId?: string;
    ownerUserId?: string;
    scope?: 'chat' | 'bot';
    conversationId?: string;
  },
  reason: NonNullable<P.ApprovalAllowance['endedReason']>
): P.ApprovalAllowance[] {
  const matches = services.store.list<P.ApprovalAllowance>('approvalAllowances', item => {
    if (item.state !== 'active') return false;
    if (filter.botId && item.botId !== filter.botId) return false;
    if (filter.ownerUserId && item.ownerUserId !== filter.ownerUserId) return false;
    if (filter.scope && item.scope !== filter.scope) return false;
    if (filter.conversationId && item.conversationId !== filter.conversationId) return false;
    return true;
  });

  const now = services.now();
  const endedList: P.ApprovalAllowance[] = [];
  for (const item of matches) {
    const ended = services.update(item, {
      state: 'ended',
      endedReason: reason,
      endedAtMs: now,
      endedByUserId: actor?.userId ?? null,
    });
    services.store.put('approvalAllowances', ended);
    services.events.emit('approval_allowance.upserted', ended, { userIds: [ended.ownerUserId] });
    const auditAction = reason === 'stopped' ? 'approval_allowance.stop' : 'approval_allowance.end';
    services.audit(actor, auditAction, ended.id, 'succeeded', {
      reason,
      scope: ended.scope,
      botId: ended.botId,
      conversationId: ended.conversationId,
    });
    endedList.push(ended);
  }
  return endedList;
}

const pageQuery = z.object({
  limit: z.coerce.number().int().min(1).max(200).optional(),
  cursor: boundedText(4096, 1).optional(),
  state: z.enum(['active', 'ended']).optional(),
}).strict();

const reviewUpdate = update.extend({
  mode: z.enum(['every_time', 'per_chat']),
});

export function createApprovalAllowanceRoutes(services: BackendServices): Route[] {
  const routes: Route[] = [
    {
      method: 'GET',
      path: '/v1/conversations/:id/approval-allowances',
      auth: 'member',
      status: 200,
      handler(context) {
        const actor = principal(context.user);
        const room = services.auth.conversation(actor, context.params.id!);
        const query = parse(pageQuery, queryObject(context.query));
        return services.page(
          context,
          services.store.list<P.ApprovalAllowance>(
            'approvalAllowances',
            item => item.conversationId === room.id && item.ownerUserId === actor.userId && (!query.state || item.state === query.state)
          )
        );
      },
    },
    {
      method: 'GET',
      path: '/v1/bots/:id/approval-allowances',
      auth: 'member',
      status: 200,
      handler(context) {
        const actor = principal(context.user);
        const bot = services.auth.bot(actor, context.params.id!);
        const query = parse(pageQuery, queryObject(context.query));
        return services.page(
          context,
          services.store.list<P.ApprovalAllowance>(
            'approvalAllowances',
            item => item.botId === bot.id && item.ownerUserId === actor.userId && (!query.state || item.state === query.state)
          )
        );
      },
    },
    {
      method: 'POST',
      path: '/v1/approval-allowances/:id/stop',
      auth: 'member',
      mutation: true,
      status: 200,
      handler(context) {
        const input = parse(update, context.body);
        const actor = principal(context.user);
        return services.mutations.execute(context, () => {
          return services.store.transaction(() => {
            const current = services.store.require<P.ApprovalAllowance>('approvalAllowances', context.params.id!);
            if (current.ownerUserId !== actor.userId) fail('forbidden', 'Only the owner can stop an approval allowance.');
            services.mutations.checkRevision(current, input.revision);
            if (current.state === 'ended') return current;
            const ended = services.update(current, {
              state: 'ended',
              endedReason: 'stopped',
              endedAtMs: services.now(),
              endedByUserId: actor.userId,
            });
            services.store.put('approvalAllowances', ended);
            services.events.emit('approval_allowance.upserted', ended, { userIds: [ended.ownerUserId] });
            services.audit(actor, 'approval_allowance.stop', ended.id, 'succeeded', {
              reason: 'stopped',
              scope: ended.scope,
              botId: ended.botId,
              conversationId: ended.conversationId,
            });
            return ended;
          });
        });
      },
    },
    {
      method: 'PATCH',
      path: '/v1/bots/:id/approval-review',
      auth: 'member',
      mutation: true,
      status: 200,
      handler(context) {
        const input = parse(reviewUpdate, context.body);
        const actor = principal(context.user);
        if (actor.kind !== 'user' || actor.id !== actor.userId || actor.sessionId === null) {
          fail('forbidden', 'Interactive user principal required.');
        }
        return services.mutations.execute(context, () => {
          return services.store.transaction(() => {
            const bot = services.auth.bot(actor, context.params.id!, true);
            if (bot.ownerUserId !== actor.userId) fail('forbidden', 'Only the Bot owner can change approval review mode.');
            services.mutations.checkRevision(bot, input.revision);

            services.store.setMetadata(`botApprovalReview:${bot.id}`, input.mode);
            endApprovalAllowances(services, actor, { botId: bot.id, scope: 'bot' }, 'review_mode_changed');
            if (input.mode === 'every_time') {
              endApprovalAllowances(services, actor, { botId: bot.id, scope: 'chat' }, 'review_mode_changed');
            }

            const updatedBot = services.update(bot, { revision: bot.revision + 1 });
            services.store.put('bots', updatedBot);
            services.events.emit('bot.upserted', updatedBot, { userIds: [bot.ownerUserId] });
            return updatedBot;
          });
        });
      },
    },
    {
      method: 'POST',
      path: '/v1/bots/:id/approval-allowances/preview',
      auth: 'member',
      status: 200,
      async handler(context) {
        parse(mutation, context.body);
        const actor = principal(context.user);
        if (actor.kind !== 'user' || actor.id !== actor.userId || actor.sessionId === null) {
          fail('forbidden', 'Interactive user principal required.');
        }
        const bot = services.auth.bot(actor, context.params.id!, true);
        if (bot.ownerUserId !== actor.userId) fail('forbidden', 'Only the Bot owner can preview bot-wide standing approvals.');

        const gov = services.store.metadata<P.Governance>('governance');
        const effective = await services.integrations.effectivePolicy(actor, bot.id);
        if (gov?.rememberedApprovals !== 'chat_and_bot' || !effective.rememberedApprovals?.bot?.length) {
          fail('policy_denied', 'Bot-wide remembered approvals require chat_and_bot governance and allowed policy categories.');
        }

        const machine = services.store.require<P.Machine>('machines', bot.machineId);
        const groups: P.ApprovalToolGroup[] = [];
        if (effective.rememberedApprovals.bot.includes('shell')) groups.push('terminal');
        if (effective.rememberedApprovals.bot.includes('files')) groups.push('file_changes', 'file_reading');

        const innerBinding = botBindingDigest(services, bot);
        const binding = { botId: bot.id, botRevision: bot.revision, groups, bindingDigest: innerBinding };
        const effects = [
          `Lemon will run any command and change any file as you on ${machine.name} without asking — in every chat and in routines. Requests started from email, Slack, X or webhooks still ask. Changing this Bot's permissions turns this off.`,
        ];
        const affected: P.ScopeEffect[] = [];
        return services.mutations.preview(actor, { id: bot.id, revision: bot.revision }, 'bot_wide_allowance', bot.name, effects, affected, binding);
      },
    },
    {
      method: 'POST',
      path: '/v1/bots/:id/approval-allowances',
      auth: 'member',
      mutation: true,
      status: 201,
      async handler(context) {
        const input = parse(confirm, context.body);
        const actor = principal(context.user);
        if (actor.kind !== 'user' || actor.id !== actor.userId || actor.sessionId === null) {
          fail('forbidden', 'Interactive user principal required.');
        }
        const bot = services.auth.bot(actor, context.params.id!, true);
        if (bot.ownerUserId !== actor.userId) fail('forbidden', 'Only the Bot owner can confirm bot-wide standing approvals.');

        const gov = services.store.metadata<P.Governance>('governance');
        const effective = await services.integrations.effectivePolicy(actor, bot.id);
        if (gov?.rememberedApprovals !== 'chat_and_bot' || !effective.rememberedApprovals?.bot?.length) {
          fail('policy_denied', 'Bot-wide remembered approvals require chat_and_bot governance and allowed policy categories.');
        }

        const groups: P.ApprovalToolGroup[] = [];
        if (effective.rememberedApprovals.bot.includes('shell')) groups.push('terminal');
        if (effective.rememberedApprovals.bot.includes('files')) groups.push('file_changes', 'file_reading');

        const innerBinding = botBindingDigest(services, bot);
        const binding = { botId: bot.id, botRevision: bot.revision, groups, bindingDigest: innerBinding };
        services.mutations.confirm(actor, { id: bot.id, revision: bot.revision }, 'bot_wide_allowance', input, binding);

        return services.mutations.execute(context, () => {
          return services.store.transaction(() => {
            endApprovalAllowances(services, actor, { botId: bot.id, scope: 'bot' }, 'review_mode_changed');
            endApprovalAllowances(services, actor, { botId: bot.id, scope: 'chat' }, 'review_mode_changed');
            const allowance = services.resource('allowance', {
              scope: 'bot' as const,
              botId: bot.id,
              conversationId: null,
              ownerUserId: bot.ownerUserId,
              toolGroups: groups,
              label: "Doesn't ask for Terminal & Files",
              state: 'active' as const,
              endedReason: null,
              endedAtMs: null,
              endedByUserId: null,
              sourceApprovalId: null,
              createdByUserId: actor.userId,
              useCount: 0,
              lastUsedAtMs: null,
            });
            services.store.put('approvalAllowances', allowance);
            services.store.setMetadata(`approvalAllowanceBinding:${allowance.id}`, { bindingDigest: innerBinding });
            services.events.emit('approval_allowance.upserted', allowance, { userIds: [allowance.ownerUserId] });
            services.audit(actor, 'approval_allowance.create', allowance.id, 'succeeded', {
              scope: allowance.scope,
              toolGroups: allowance.toolGroups,
              botId: allowance.botId,
            });

            const updatedBot = services.update(bot, { revision: bot.revision + 1 });
            services.store.put('bots', updatedBot);
            services.events.emit('bot.upserted', updatedBot, { userIds: [bot.ownerUserId] });
            return allowance;
          });
        });
      },
    },
  ];

  return routes;
}
