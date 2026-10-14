import { createHash, randomBytes } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { AccessService, Authentication, BackendServices, Principal } from './services';
import { ApiError, fail } from './errors';
import { authenticateIntegration } from '../enterprise/tokens';
import { ensureTeamDM } from './conversations';
import { hasProductAccess } from '../enterprise/policy';
export interface SessionSecret { id: string; tokenDigest: string; revoked: boolean }
export interface Credential { id: string; passwordHash: string }
export interface RevocationHooks {
  beforeRevokeUser?: (principal: Principal) => void;
  onRevokeUser?: (userId: string) => Promise<void> | void;
  onRevokeSession?: (sessionId: string) => Promise<void> | void;
  onLogoutUser?: (userId: string) => Promise<void> | void;
}
export interface AccountDeletionFence {
  status: 'running' | 'outcome_unknown' | 'completed';
  operationId: string;
  nonce: string;
  capabilityDigest: string;
  encryptedCapability: string;
  phase: 'prepared' | 'sessions_revoked' | 'resources' | 'providers' | 'finalizing' | 'completed';
  targets: { collection: string; id: string }[];
  completedIds: string[];
  providerAcknowledged: boolean;
  productCleanupComplete: boolean;
  lastErrorCode: P.ErrorCode | null;
  providerBinding: P.JSONObject;
  createdAtMs: number;
  updatedAtMs: number;
}
const lifetime = 30 * 24 * 60 * 60 * 1000;
export const opaqueToken = () => randomBytes(32).toString('base64url');
export const tokenSha256 = (token: string) => createHash('sha256').update(token).digest('hex');
const record = (value: unknown): Record<string, unknown> | null => typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null;
const productCollections: Record<string, true> = {
  bots: true, conversations: true, machines: true, machineInvites: true, terminals: true,
  entries: true, runs: true, routineRuns: true, webhookKeys: true, drafts: true, memories: true,
  reminders: true, routines: true, skills: true, attachments: true, approvals: true, questions: true,
  humanSteps: true, secretRequests: true, consents: true, notifications: true, sections: true,
  composerDrafts: true, voiceSessions: true, milestones: true, feedbacks: true, connectors: true,
  connectorAuths: true, channelBindings: true, channelPrincipalLinks: true, channelLinkFlows: true,
  emailAccounts: true, emailMessages: true, xConnections: true, botGrants: true, activity: true,
  preferenceChanges: true, memoryImportPreviews: true, templates: true,
};

/** Session authority is separate from wire sessions and all bot/hook/integration credentials. */
export function createAccessService(services: BackendServices, hooks: RevocationHooks = {}): AccessService {
  const { store } = services;
  const workspace = () => store.require<P.Workspace>('workspaces', store.metadata<string>('workspaceId') ?? '');
  const user = (userId: string) => store.require<P.User>('users', userId);
  const member = (userId: string) => {
    const result = store.list<P.Member>('members', row => row.userId === userId)[0];
    if (!result) fail('unauthenticated', 'Account is not an enabled workspace member.');
    return result;
  };
  function accountBlocked(principal: Principal, userId: string): boolean {
    const fence = store.metadata<AccountDeletionFence>(`accountDeletion:${userId}`);
    if (!fence) return false;
    const capability = principal.kind === 'user' && principal.sessionId === null && principal.userId === userId ? principal.scopes?.find(scope => scope.startsWith('account_delete:')) : undefined;
    return fence.status !== 'running' || !capability || services.mutations.digest(capability.slice('account_delete:'.length)) !== fence.capabilityDigest;
  }
  function enabled(principal: Principal, allowWorkspaceRepair = false): P.Member {
    // Hook/integration snapshots are constructed only after verified server ingress;
    // product member routes never authenticate these credential kinds.
    if (principal.kind === 'bot' || principal.workspaceId !== store.metadata<string>('workspaceId')) fail('forbidden', 'Inherited workspace membership is required.');
    const current = member(principal.userId);
    if (!current.enabled) fail('unauthenticated', 'Account is not an enabled workspace member.');
    if (accountBlocked(principal, principal.userId)) fail('unauthenticated', 'Account deletion has revoked account access.');
    if (!hasProductAccess(services, principal.userId) && (!allowWorkspaceRepair || principal.kind !== 'user' || current.role === 'member')) fail('policy_denied', 'Workspace or directory policy denies product access.');
    return current;
  }
  function requireRole(principal: Principal, role: 'admin' | 'owner') {
    if (principal.kind !== 'user') fail('forbidden', 'A primary user session is required for workspace administration.');
    const current = enabled(principal, true);
    if (current.role !== 'owner' && (role === 'owner' || current.role !== 'admin')) fail('forbidden', 'Workspace role does not authorize this action.');
  }
  function readableBot(principal: Principal, bot: P.Bot, manage = false): boolean {
    if (accountBlocked(principal, bot.ownerUserId)) return false;
    if (principal.kind === 'bot') return principal.botId === bot.id && !manage;
    enabled(principal);
    if (bot.visibility === 'personal') return bot.ownerUserId === principal.userId;
    const maintainer = bot.ownerUserId === principal.userId || bot.managerUserIds.includes(principal.userId);
    return maintainer || (!manage && bot.published);
  }
  function bot(principal: Principal, botId: string, manage = false): P.Bot {
    const result = store.get<P.Bot>('bots', botId);
    if (!result || !readableBot(principal, result, manage)) fail('not_found', 'Bot not found.');
    const sidebar = store.metadata<P.SidebarState>(`botSidebar:${principal.userId}:${botId}`);
    const mainConversationId = result.visibility === 'team' && principal.kind !== 'bot' ? ensureTeamDM(services, result, principal.userId).id : result.mainConversationId;
    const base = result.ownerUserId === principal.userId && result.mainConversationId !== mainConversationId ? store.require<P.Bot>('bots', botId) : result;
    const activeRunIds = principal.kind === 'bot' ? base.activeRunIds : base.activeRunIds.filter(runId => {
      const run = store.get<P.Run>('runs', runId);
      return run !== null && canRead(principal, 'runs', run);
    });
    return { ...base, mainConversationId, activeRunIds, sidebar: sidebar ?? { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true } };
  }
  function conversation(principal: Principal, conversationId: string): P.Conversation {
    enabled(principal);
    const result = store.get<P.Conversation>('conversations', conversationId);
    if (!result || !result.botIds.every(id => { const value = store.get<P.Bot>('bots', id); return value !== null && readableBot(principal, value); })) fail('not_found', 'Conversation not found.');
    const privateRoom = result.kind === 'dm' || result.kind === 'team_dm' || result.kind === 'task';
    if (privateRoom ? result.ownerUserId !== principal.userId : result.ownerUserId !== principal.userId && !result.humanUserIds.includes(principal.userId)) fail('not_found', 'Conversation not found.');
    const read = store.metadata<{ throughSeq: number; unread: boolean }>(`conversationRead:${principal.userId}:${conversationId}`);
    const throughSeq = read?.throughSeq ?? 0;
    const unreadCount = store.list<P.TranscriptEntry>('entries', entry => entry.conversationId === result.id && entry.seq > throughSeq && (entry.targetedUserId === null || entry.targetedUserId === principal.userId)).length;
    return { ...result, lastReadSeq: throughSeq, unreadCount: Math.max(unreadCount, read?.unread ? 1 : 0) };
  }
  function machine(principal: Principal, machineId: string, manage = false): P.Machine {
    const current = enabled(principal);
    const result = store.get<P.Machine>('machines', machineId);
    const configured = services.config.operatorExtras?.machineManagementUserIds;
    const management = principal.kind === 'user' && (current.role === 'owner' || current.role === 'admin' && Array.isArray(configured) && configured.includes(principal.userId));
    if (!result || !(result.ownerUserId === principal.userId || management || (!manage && result.accessUserIds.includes(principal.userId)))) fail('not_found', 'Machine not found.');
    return result;
  }
  function attachment(principal: Principal, attachmentId: string): P.Attachment {
    enabled(principal);
    const result = store.get<P.Attachment>('attachments', attachmentId);
    if (!result || !canRead(principal, 'attachments', result)) fail('not_found', 'Attachment not found.');
    return result;
  }
  function canRead(principal: Principal, collection: string, entity: unknown): boolean {
    const value = record(entity);
    if (!value) return false;
    try {
      enabled(principal, productCollections[collection] !== true);
      const own = (field: string) => value[field] === principal.userId;
      const room = () => {
        if (typeof value.conversationId === 'string') return Boolean(conversation(principal, value.conversationId));
        const entry = typeof value.entryId === 'string' ? store.get<P.TranscriptEntry>('entries', value.entryId) : null;
        return entry !== null && (entry.targetedUserId === null || entry.targetedUserId === principal.userId) && Boolean(conversation(principal, entry.conversationId));
      };
      const visibleBot = () => typeof value.botId === 'string' && Boolean(bot(principal, value.botId));
      switch (collection) {
        case 'users': return value.id === principal.userId;
        case 'members': case 'workspaces': return true;
        case 'invites': case 'auditRecords': requireRole(principal, 'admin'); return true;
        case 'integrationTokens': requireRole(principal, 'owner'); return true;
        case 'accountTeardowns': requireRole(principal, 'owner'); return value.workspaceId === principal.workspaceId;
        case 'authSessions': case 'devices': case 'notifications': case 'sections': case 'composerDrafts': case 'milestones': case 'feedbacks': case 'identityLinks': case 'emailAccounts': case 'xConnections': case 'channelPrincipalLinks': case 'channelLinkFlows': return own('userId');
        case 'voiceSessions': return own('userId') && room();
        case 'emailMessages': return typeof value.accountId === 'string' && store.get<P.EmailAccount>('emailAccounts', value.accountId)?.userId === principal.userId;
        case 'bots': return typeof value.id === 'string' && Boolean(bot(principal, value.id));
        case 'conversations': return typeof value.id === 'string' && Boolean(conversation(principal, value.id));
        case 'machines': return typeof value.id === 'string' && Boolean(machine(principal, value.id));
        case 'machineInvites': return typeof value.machineId === 'string' && Boolean(machine(principal, value.machineId, true));
        case 'terminals': return own('userId') && principal.deviceId !== null && value.deviceId === principal.deviceId;
        case 'entries': return (value.targetedUserId === null || value.targetedUserId === principal.userId) && room();
        case 'approvals': case 'questions': case 'humanSteps': case 'secretRequests': case 'consents': {
          const gate = record(value.gate);
          return gate?.targetUserId === principal.userId && room();
        }
        case 'runs': return room();
        case 'routineRuns': {
          if (principal.kind === 'hook') {
            const routine = typeof value.routineId === 'string' ? store.get<P.Routine>('routines', value.routineId) : null;
            const key = routine ? store.metadata<{ id: string }>(`routineKey:${routine.id}`) : null;
            if (!routine || routine.ownerUserId !== principal.userId || key?.id !== principal.id) return false;
          }
          return room();
        }
        case 'webhookKeys': {
          const routine = typeof value.routineId === 'string' ? store.get<P.Routine>('routines', value.routineId) : null;
          return routine !== null && routine.ownerUserId === principal.userId && store.metadata<{ id: string }>(`routineKey:${routine.id}`)?.id === value.id;
        }
        case 'drafts': return own('ownerUserId') && room();
        case 'memories': return value.scope === 'private_note' ? own('userId') && visibleBot() : value.scope === 'personal' ? visibleBot() && (own('userId') || typeof value.botId === 'string' && store.get<P.Bot>('bots', value.botId)?.ownerUserId === principal.userId) : value.scope === 'team' && visibleBot();
        case 'routines': return own('ownerUserId') && visibleBot();
        case 'reminders': return own('userId') && visibleBot() && room();
        case 'skills': return own('ownerUserId') || (value.scope === 'team' && typeof value.botId === 'string' && visibleBot());
        case 'attachments': {
          if (own('ownerUserId')) return true;
          const linkedBot = typeof value.botId === 'string' ? store.get<P.Bot>('bots', value.botId) : null;
          if (linkedBot && typeof value.id === 'string' && readableBot(principal, linkedBot) && (linkedBot.referenceAttachmentIds.includes(value.id) || linkedBot.avatar.attachmentId === value.id)) return true;
          for (const share of store.list<{ attachmentId: string; conversationId: string }>('attachmentShares', share => share.attachmentId === value.id)) {
            try { conversation(principal, share.conversationId); return true; } catch (error) { if (!(error instanceof ApiError)) throw error; }
          }
          return room();
        }
        case 'connectors': return own('ownerUserId') || (value.shared === true && visibleBot());
        case 'connectorAuths': return typeof value.connectorId === 'string' && store.get<P.Connector>('connectors', value.connectorId)?.ownerUserId === principal.userId;
        case 'channelBindings': return own('ownerUserId') || visibleBot();
        case 'botGrants': return visibleBot();
        case 'preferenceChanges': case 'memoryImportPreviews': return own('userId') && visibleBot();
        case 'activity': return visibleBot() && (value.conversationId === null || room());
        case 'templates': return value.audience === 'workspace' || value.audience === 'public' && store.metadata<P.Policies>('policies')?.publicTemplates === true;
        case 'policies': return true;
        case 'policyRules': return own('ownerUserId') || value.required === true && value.ownerUserId === null;
        default: return services.integrations.canReadResource?.(principal, collection, entity) ?? false;
      }
    } catch (error) {
      if (error instanceof ApiError) return false;
      throw error;
    }
  }
  async function authenticate(request: Request, policy: Authentication = 'member'): Promise<Principal | null> {
    if (policy === 'public') return null;
    const header = request.headers.get('authorization');
    if (!header) { if (policy === 'optional') return null; fail('unauthenticated', 'Sign in to continue.'); }
    const match = /^Bearer ([A-Za-z0-9_-]{16,512})$/i.exec(header);
    if (!match) fail('unauthenticated', 'Invalid credential.');
    const digest = services.mutations.digest(match[1]);
    if (store.metadata<string>('workspaceId') === null) fail('unauthenticated', 'Workspace has not been configured.');
    const workspaceId = workspace().id;
    if (policy === 'bot') {
      const authority = store.list<{ id: string; botId: string; tokenDigest: string; revoked: boolean }>('botTokens', row => row.tokenDigest === digest && !row.revoked)[0];
      const value = authority && store.get<P.Bot>('bots', authority.botId);
      if (!value || !member(value.ownerUserId).enabled || !workspace().enabled || store.metadata(`accountDeletion:${value.ownerUserId}`)) fail('unauthenticated', 'Invalid credential.');
      return { kind: 'bot', id: value.id, userId: value.ownerUserId, workspaceId, role: member(value.ownerUserId).role, sessionId: null, botId: value.id, deviceId: null };
    }
    if (policy === 'integration') {
      const authority = authenticateIntegration(services, request);
      if (!authority || authority.workspaceId !== workspaceId || !workspace().enabled) fail('unauthenticated', 'Invalid credential.');
      return authority;
    }
    if (policy === 'optional' && request.method === 'GET' && new URL(request.url).pathname === '/v1/audit') {
      const authority = authenticateIntegration(services, request, ['audit_export']);
      if (authority && authority.workspaceId === workspaceId && store.get<P.IntegrationToken>('integrationTokens', authority.id)?.kind === 'audit_export') {
        if (!workspace().enabled) fail('policy_denied', 'Workspace is disabled.');
        return authority;
      }
    }
    if (policy === 'hook') {
      for (const routine of store.list<P.Routine>('routines', row => row.enabled && row.trigger.kind === 'webhook')) {
        const key = store.metadata<{ id: string; digest: string }>(`routineKey:${routine.id}`);
        if (key?.digest !== tokenSha256(match[1])) continue;
        const current = member(routine.ownerUserId);
        if (!current.enabled || !workspace().enabled || store.metadata(`accountDeletion:${routine.ownerUserId}`) || !store.get<P.Bot>('bots', routine.botId)) fail('unauthenticated', 'Invalid credential.');
        return { kind: 'hook', id: key.id, userId: routine.ownerUserId, workspaceId, role: current.role, sessionId: null, botId: routine.botId, deviceId: null };
      }
      fail('unauthenticated', 'Invalid credential.');
    }
    const authority = store.list<SessionSecret>('sessionSecrets', row => row.tokenDigest === digest && !row.revoked)[0];
    const session = authority && store.get<P.AuthSession>('authSessions', authority.id);
    if (!session || session.expiresAtMs <= services.now()) fail('unauthenticated', 'Session expired or revoked.');
    const current = member(session.userId);
    const result: Principal = { kind: 'user', id: session.userId, userId: session.userId, workspaceId, role: current.role, sessionId: session.id, botId: null, deviceId: session.deviceId };
    enabled(result, true);
    if (policy === 'admin' || policy === 'owner') requireRole(result, policy);
    const seenAtMs = services.now();
    if (session.lastSeenAtMs !== seenAtMs) store.put('authSessions', services.update(session, { lastSeenAtMs: seenAtMs }));
    return result;
  }
  function session(userId: string, deviceId: string | null = null): Promise<P.AuthResult> {
    const current = member(userId);
    if (!current.enabled) fail('unauthenticated', 'Account is not an enabled workspace member.');
    if (!hasProductAccess(services, userId) && current.role === 'member') fail('policy_denied', 'Workspace or directory policy denies product access.');
    if (store.metadata(`accountDeletion:${userId}`)) fail('unauthenticated', 'Account deletion has revoked account access.');
    if (deviceId !== null && store.get<P.Device>('devices', deviceId)?.userId !== userId) fail('not_found', 'Device not found.');
    const token = opaqueToken();
    const result = services.resource('session', { userId, deviceId, expiresAtMs: services.now() + lifetime, lastSeenAtMs: services.now(), current: false });
    store.transaction(() => {
      store.put('authSessions', result);
      store.put<SessionSecret>('sessionSecrets', { id: result.id, tokenDigest: services.mutations.digest(token), revoked: false });
    });
    return Promise.resolve({ token, session: { ...result, current: true }, user: user(userId), workspace: workspace(), member: current });
  }
  async function revokeUser(userId: string) {
    store.transaction(() => {
      for (const value of store.list<P.AuthSession>('authSessions', row => row.userId === userId)) {
        const authority = store.get<SessionSecret>('sessionSecrets', value.id);
        if (authority) store.put('sessionSecrets', { ...authority, revoked: true });
        store.remove('authSessions', value.id);
      }
      for (const value of store.list<P.Device>('devices', row => row.userId === userId)) {
        store.setMetadata(`devicePush:${value.id}`, null);
        store.setMetadata(`devicePushRegisteredAt:${value.id}`, null);
        const updated = services.update(value, { pushEnabled: false });
        store.put('devices', updated);
        services.events.emit('device.upserted', updated, { userIds: [userId] });
      }
      services.gates.cancelUser(userId);
    });
    await hooks.onRevokeUser?.(userId);
  }
  function issueReauth(userId: string): P.ReauthResult {
    if (!member(userId).enabled) fail('unauthenticated', 'Account is disabled.');
    if (store.metadata(`accountDeletion:${userId}`)) fail('unauthenticated', 'Account deletion has revoked account access.');
    const reauthToken = opaqueToken();
    const expiresAtMs = services.now() + 5 * 60 * 1000;
    store.put('reauthTokens', { id: services.mutations.digest(reauthToken), userId, expiresAtMs, used: false });
    return { reauthToken, expiresAtMs };
  }
  function consumeReauth(userId: string, token: string) {
    store.transaction(() => {
      const result = store.get<{ id: string; userId: string; expiresAtMs: number; used: boolean }>('reauthTokens', services.mutations.digest(token));
      if (!result || result.userId !== userId || result.used || result.expiresAtMs <= services.now()) fail('unauthenticated', 'Reauthentication expired or invalid.');
      store.put('reauthTokens', { ...result, used: true });
    });
  }
  return { authenticate, user, member, requireRole, bot, conversation, machine, attachment, canRead, revokeUser, session, issueReauth, consumeReauth };
}
