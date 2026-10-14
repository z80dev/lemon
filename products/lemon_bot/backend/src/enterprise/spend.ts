import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { ApiError } from '../core/errors';
import { measureUsage } from '../core/resources';
import { fetchJson, principal } from '../integrations/common';
import { providerSpendSource } from '../integrations/config';
const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
const id = z.string().min(1).max(256);
const amount = z.number().finite().nonnegative();
const create = z.object({ clientNonce: nonce, scope: z.enum(['workspace', 'user', 'bot', 'routine']), subjectId: id.optional(), period: z.enum(['day', 'week', 'month']), limitUsd: amount, warningPercent: z.number().int().min(1).max(99), providerAccount: z.string().min(1).max(256).optional() }).strict();
const patch = z.object({ clientNonce: nonce, revision: z.number().int().positive(), limitUsd: amount.optional(), warningPercent: z.number().int().min(1).max(99).optional(), enabled: z.boolean().optional() }).strict();
const remove = z.object({ clientNonce: nonce, revision: z.number().int().positive() }).strict();
/** Spending periods reset at UTC day, ISO week (Monday), or calendar-month boundaries. */
export function spendWindow(period: P.SpendLimit['period'], atMs: number): { fromAtMs: number; toAtMs: number } {
  const at = new Date(atMs); const midnight = Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate());
  if (period === 'day') return { fromAtMs: midnight, toAtMs: midnight + 86400000 };
  if (period === 'week') { const fromAtMs = midnight - ((at.getUTCDay() + 6) % 7) * 86400000; return { fromAtMs, toAtMs: fromAtMs + 7 * 86400000 }; }
  return { fromAtMs: Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), 1), toAtMs: Date.UTC(at.getUTCFullYear(), at.getUTCMonth() + 1, 1) };
}
export function spendStatus(limit: P.SpendLimit, measurement: { costUsd: number | null; incomplete: boolean }, atMs: number): P.SpendStatus {
  const resetsAtMs = spendWindow(limit.period, atMs).toAtMs;
  if (measurement.incomplete || measurement.costUsd === null || !Number.isFinite(measurement.costUsd) || measurement.costUsd < 0) return { limit, spentUsd: null, remainingUsd: null, resetsAtMs, state: 'unknown' };
  const spentUsd = measurement.costUsd; return { limit, spentUsd, remainingUsd: Math.max(0, limit.limitUsd - spentUsd), resetsAtMs, state: spentUsd >= limit.limitUsd ? 'exhausted' : spentUsd >= limit.limitUsd * limit.warningPercent / 100 ? 'warning' : 'ok' };
}
export function createSpendServices(services: BackendServices) {
  function canRead(who: Principal, limit: P.SpendLimit): boolean {
    if (limit.scope === 'workspace') return who.role === 'admin' || who.role === 'owner';
    if (limit.scope === 'user') return limit.subjectId === who.userId;
    if (limit.scope === 'bot') { try { return services.auth.bot(who, limit.subjectId!).ownerUserId === who.userId; } catch { return false; } }
    const routine = services.store.get<P.Routine>('routines', limit.subjectId!); return routine?.ownerUserId === who.userId;
  }
  function authority(who: Principal, scope: P.SpendLimit['scope'], subjectId: string | null): void {
    if (scope === 'workspace') { services.auth.requireRole(who, 'admin'); if (subjectId !== null) throw new ApiError('invalid_request', 'Workspace spend limit has no subjectId.'); return; }
    if (!subjectId) throw new ApiError('invalid_request', 'This spend scope requires subjectId.');
    if (scope === 'user') { if (subjectId !== who.userId) throw new ApiError('forbidden', 'Set only your own personal spending limit.'); services.auth.member(subjectId); }
    else if (scope === 'bot') { if (services.auth.bot(who, subjectId).ownerUserId !== who.userId) throw new ApiError('forbidden', 'Only the bot owner can set its spending limit.'); }
    else { const routine = services.store.require<P.Routine>('routines', subjectId); if (routine.ownerUserId !== who.userId) throw new ApiError('not_found', 'Routine is not available.'); }
  }
  async function status(who: Principal, limit: P.SpendLimit): Promise<P.SpendStatus> {
    const window = spendWindow(limit.period, services.now());
    if (limit.providerAccount) {
      const source = providerSpendSource(services, limit.providerAccount);
      if (!source) return spendStatus(limit, { costUsd: null, incomplete: true }, services.now());
      const toAtMs = Math.min(services.now() + 1, window.toAtMs);
      const url = new URL(`${source.apiBaseUrl.replace(/\/$/, '')}/spend`);
      url.searchParams.set('fromAtMs', String(window.fromAtMs)); url.searchParams.set('toAtMs', String(toAtMs));
      url.searchParams.set('providerAccount', limit.providerAccount); url.searchParams.set('scope', limit.scope);
      if (limit.subjectId) url.searchParams.set('subjectId', limit.subjectId);
      const response = await fetchJson(url.href, { headers: { Authorization: `Bearer ${await services.secret(source.secretRef)}`, Accept: 'application/json' } }, { allowedOrigins: [new URL(source.apiBaseUrl).origin] });
      const parsed = z.object({ providerAccount: id, scope: z.enum(['workspace', 'user', 'bot', 'routine']), subjectId: id.nullable(), currency: z.literal('USD'), fromAtMs: z.number().int().nonnegative(), toAtMs: z.number().int().nonnegative(), costUsd: amount.nullable(), complete: z.boolean() }).strict().safeParse(response);
      if (!parsed.success || parsed.data.providerAccount !== limit.providerAccount || parsed.data.scope !== limit.scope || parsed.data.subjectId !== limit.subjectId || parsed.data.fromAtMs !== window.fromAtMs || parsed.data.toAtMs !== toAtMs) throw new ApiError('upstream_unavailable', 'Provider spend reconciliation returned a mismatched account, scope or measurement window.');
      return spendStatus(limit, { costUsd: parsed.data.costUsd, incomplete: !parsed.data.complete }, services.now());
    }
    const report = await measureUsage(services, who, { fromAtMs: window.fromAtMs, toAtMs: Math.min(services.now() + 1, window.toAtMs), groupBy: limit.scope === 'routine' ? 'routine' : limit.scope === 'user' ? 'user' : 'bot', ...(limit.scope === 'bot' ? { botId: limit.subjectId! } : {}), ...(limit.scope === 'routine' ? { routineId: limit.subjectId! } : {}), ...(limit.scope === 'user' ? { userId: limit.subjectId! } : {}), workspace: limit.scope === 'workspace', ...(limit.providerAccount ? { providerAccount: limit.providerAccount } : {}) });
    return spendStatus(limit, { costUsd: report.totals.costUsd, incomplete: report.incomplete }, services.now());
  }
  async function admission(who: Principal, botId: string, routineId?: string): Promise<void> {
    const limits = services.store.list<P.SpendLimit>('spendLimits', limit => limit.enabled && (limit.scope === 'workspace' || limit.scope === 'user' && limit.subjectId === who.userId || limit.scope === 'bot' && limit.subjectId === botId || limit.scope === 'routine' && limit.subjectId === routineId));
    for (const limit of limits) {
      // Workspace limits must use workspace attribution even for a member run; privileged measurement
      // returns only admission outcome, never an admin's private usage projection to this caller.
      let measurementPrincipal = who;
      if (limit.scope === 'workspace' && who.role === 'member') { const ownerId = services.store.require<P.Workspace>('workspaces', who.workspaceId).ownerUserId; const owner = services.auth.member(ownerId); measurementPrincipal = { ...who, id: ownerId, userId: ownerId, role: owner.role, sessionId: null, deviceId: null, kind: 'user', botId: null }; }
      const current = await status(measurementPrincipal, limit);
      if (current.state === 'unknown' || current.state === 'exhausted') { services.audit(who, 'spend.admission', limit.id, 'denied', { state: current.state, botId, ...(routineId ? { routineId } : {}) }); throw new ApiError('policy_denied', current.state === 'unknown' ? 'Enforced spend limit requires complete authoritative pricing and attribution; refresh the usage ledger before new work.' : 'A matching spend limit is exhausted; new work is blocked until reset or an authorized limit change.', true, { limitId: limit.id, state: current.state, resetsAtMs: current.resetsAtMs }); }
      if (current.state === 'warning') services.audit(who, 'spend.warning', limit.id, 'succeeded', { botId, state: current.state });
    }
  }
  return { canRead, authority, status, admission };
}
export function createSpendRoutes(services: BackendServices): Route[] {
  const spend = createSpendServices(services);
  return [
    { method: 'GET', path: '/v1/spend-limits', auth: 'member', handler: async context => { const who = principal(context); const limits = services.store.list<P.SpendLimit>('spendLimits', limit => spend.canRead(who, limit)); const page = services.page(context, limits); return { items: await Promise.all(page.items.map(limit => spend.status(who, limit))), nextCursor: page.nextCursor }; } },
    { method: 'POST', path: '/v1/spend-limits', auth: 'member', status: 201, handler: context => { const who = principal(context); const body = create.parse(context.body); spend.authority(who, body.scope, body.subjectId ?? null); if (services.store.list<P.SpendLimit>('spendLimits', limit => limit.scope === body.scope && limit.subjectId === (body.subjectId ?? null) && limit.period === body.period && limit.providerAccount === (body.providerAccount ?? null)).length) throw new ApiError('conflict', 'Update the existing limit for this scope, period and provider account.'); const { clientNonce: _nonce, subjectId: _subject, providerAccount: _provider, ...fields } = body; const result: P.SpendLimit = services.resource('limit', { ...fields, subjectId: body.subjectId ?? null, providerAccount: body.providerAccount ?? null, enabled: true, enforcement: 'block_new_runs' }); return services.store.transaction(() => { services.store.put('spendLimits', result); services.events.emit('spend_limit.upserted', result, result.scope === 'workspace' ? { admin: true } : { userIds: [who.userId] }); services.audit(who, 'spend.create', result.id, 'succeeded', {}, context.requestId); return result; }); } },
    { method: 'PATCH', path: '/v1/spend-limits/:id', auth: 'member', handler: context => { const who = principal(context); const body = patch.parse(context.body); const value = services.store.require<P.SpendLimit>('spendLimits', context.params.id!); spend.authority(who, value.scope, value.subjectId); services.mutations.checkRevision(value, body.revision); const { clientNonce: _nonce, revision: _revision, ...changes } = body; return services.store.transaction(() => { const result = services.update(value, changes); services.store.put('spendLimits', result); services.events.emit('spend_limit.upserted', result, value.scope === 'workspace' ? { admin: true } : { userIds: [who.userId] }); services.audit(who, 'spend.update', result.id, 'succeeded', {}, context.requestId); return result; }); } },
    { method: 'DELETE', path: '/v1/spend-limits/:id', auth: 'member', handler: context => { const who = principal(context); const body = remove.parse(context.body); const value = services.store.require<P.SpendLimit>('spendLimits', context.params.id!); spend.authority(who, value.scope, value.subjectId); services.mutations.checkRevision(value, body.revision); services.store.remove('spendLimits', value.id); services.audit(who, 'spend.delete', value.id, 'succeeded', {}, context.requestId); return { id: value.id, deleted: true }; } },
  ];
}
