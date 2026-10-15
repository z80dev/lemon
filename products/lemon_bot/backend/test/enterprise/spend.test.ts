import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { createSpendServices, spendStatus, spendWindow } from '../../src/enterprise/spend';
import { additionalOwner, closeFixture, fixture as ownerFixture } from '../integrations/channels-fixture';
const at = Date.UTC(2026, 9, 14, 10, 35);
const limit: P.SpendLimit = { id: 'l', revision: 1, createdAtMs: 1, updatedAtMs: 1, scope: 'user', subjectId: 'u', period: 'day', limitUsd: 20, warningPercent: 75, enabled: true, enforcement: 'block_new_runs', providerAccount: null };
describe('authoritative spend semantics', () => {
  test('missing or incomplete price is unknown, never a free zero allowance', () => {
    for (const measurement of [{ costUsd: null, incomplete: false }, { costUsd: 0, incomplete: true }, { costUsd: NaN, incomplete: false }, { costUsd: -1, incomplete: false }]) {
      const status = spendStatus(limit, measurement, at); expect(status.state).toBe('unknown'); expect(status.spentUsd).toBeNull(); expect(status.remainingUsd).toBeNull();
    }
  });
  test('warning and equality exhaustion are exact; admitted overspend is displayed without negative remaining', () => {
    expect(spendStatus(limit, { costUsd: 14.99, incomplete: false }, at).state).toBe('ok');
    expect(spendStatus(limit, { costUsd: 15, incomplete: false }, at).state).toBe('warning');
    expect(spendStatus(limit, { costUsd: 20, incomplete: false }, at).state).toBe('exhausted');
    expect(spendStatus(limit, { costUsd: 22, incomplete: false }, at).remainingUsd).toBe(0);
  });
  test('zero-dollar ceiling admits no new paid or measured-zero work', () => {
    expect(spendStatus({ ...limit, limitUsd: 0 }, { costUsd: 0, incomplete: false }, at).state).toBe('exhausted');
  });
  test('UTC day and ISO week do not depend on user timezone or DST', () => {
    expect(spendWindow('day', at)).toEqual({ fromAtMs: Date.UTC(2026, 9, 14), toAtMs: Date.UTC(2026, 9, 15) });
    expect(spendWindow('week', Date.UTC(2026, 9, 18, 23, 59))).toEqual({ fromAtMs: Date.UTC(2026, 9, 12), toAtMs: Date.UTC(2026, 9, 19) });
  });
  test('calendar month handles leap-year February and year rollover', () => {
    expect(spendWindow('month', Date.UTC(2028, 1, 29))).toEqual({ fromAtMs: Date.UTC(2028, 1, 1), toAtMs: Date.UTC(2028, 2, 1) });
    expect(spendWindow('month', Date.UTC(2026, 11, 31))).toEqual({ fromAtMs: Date.UTC(2026, 11, 1), toAtMs: Date.UTC(2027, 0, 1) });
  });
});

test('workspace spend admission measures actual aggregate cost without borrowing the workspace owner identity', async () => {
  const base = ownerFixture(), { services, principal, bot } = base;
  try {
    base.setClock(at);
    const other = additionalOwner(services, bot, 'workspace_owner', 'owner');
    const workspace = services.store.require<P.Workspace>('workspaces', principal.workspaceId);
    services.store.put('workspaces', { ...workspace, ownerUserId: other.principal.userId });
    const ownRun: P.Run = { ...services.resource('run', { botId: bot.id, conversationId: bot.mainConversationId, initiatorUserId: principal.userId, clientNonce: 'measured_owner_operation', status: 'succeeded', error: null, startedAtMs: at - 2, completedAtMs: at - 1, routineRunId: null }), id: 'own-run' };
    const otherRun: P.Run = { ...ownRun, id: 'other-run', botId: other.bot.id, conversationId: other.bot.mainConversationId, initiatorUserId: other.principal.userId };
    services.store.put('runs', ownRun); services.store.put('runs', otherRun);
    const workspaceLimit: P.SpendLimit = { ...limit, id: 'workspace-limit', scope: 'workspace', subjectId: null, limitUsd: 10 };
    services.store.put('spendLimits', workspaceLimit);
    const member = services.auth.member;
    services.auth.member = userId => {
      if (userId !== principal.userId) throw new Error('Another account cannot supply spend-admission authority.');
      return member(userId);
    };
    const records = [
      { id: 'own-cost', runId: ownRun.id, sessionKey: null, agentId: bot.profileId, atMs: at - 1, model: 'priced', provider: 'provider', inputTokens: 2, outputTokens: 3, totalTokens: 5, costUsd: 3, priceKnown: true },
      { id: 'other-cost', runId: otherRun.id, sessionKey: null, agentId: other.bot.profileId, atMs: at - 1, model: 'priced', provider: 'provider', inputTokens: 2, outputTokens: 3, totalTokens: 5, costUsd: 11, priceKnown: true },
    ];
    services.lemon.methods = ['usage.records'];
    services.lemon.call = async <T>(method: string): Promise<T> => {
      if (method !== 'usage.records') throw new Error('Unexpected native ledger operation.');
      return { records, nextCursor: null, incomplete: false } as T;
    };
    const spend = createSpendServices(services);
    await expect(spend.status(principal, workspaceLimit)).rejects.toMatchObject({ code: 'not_found' });
    await expect(spend.admission(principal, bot.id)).rejects.toMatchObject({ code: 'policy_denied', details: { limitId: workspaceLimit.id, state: 'exhausted' } });
  } finally { closeFixture(services); }
});

test('foreign Bot admission is denied even without a matching spend limit', async () => {
  const base = ownerFixture(), { services, principal, bot } = base;
  try {
    const other = additionalOwner(services, bot, 'foreign', 'owner');
    // Legacy broad metadata access cannot turn a spend check into live Bot authority.
    services.auth.bot = () => other.bot;
    let calls = 0;
    services.lemon.call = async () => { calls++; throw new Error('No provider operation is authorized.'); };
    await expect(createSpendServices(services).admission(principal, other.bot.id)).rejects.toMatchObject({ code: 'not_found' });
    expect(calls).toBe(0);
  } finally { closeFixture(services); }
});
