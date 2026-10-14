import { afterEach, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { directoryAffectedUsers } from '../../src/enterprise/policy';
import { refreshEffectivePolicy } from '../../src/enterprise/enforcement';
import type { BackendServices, Principal } from '../../src/core/services';
import { closeFixture, fixture as ownerFixture } from '../integrations/channels-fixture';
const serviceFixtures: BackendServices[] = [];
afterEach(() => { for (const services of serviceFixtures.splice(0)) closeFixture(services); });
const group = (members: string[], revision = 1): P.DirectoryGroup => ({ id: 'engineering', revision, createdAtMs: 1, updatedAtMs: revision, name: 'Engineering', source: 'oidc', externalId: 'engineering-idp', memberUserIds: members });
const policy = (revision = 1): P.GroupPolicy => ({ id: 'engineering-policy', revision, createdAtMs: 1, updatedAtMs: revision, directoryGroupId: 'engineering', productAccess: true, capabilityModes: {}, requiredRuleIds: [], localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, networkPolicyId: null, reviewExempt: false });

test('signed membership changes cannot cancel unrelated existing group members', () => {
  const old = group(['alice', 'bob']);
  expect(directoryAffectedUsers([old], [group(['alice', 'bob', 'carol'], 2)], [policy()], [policy()])).toEqual(['carol']);
  expect(directoryAffectedUsers([old], [group(['alice'], 2)], [policy()], [policy()])).toEqual(['bob']);
});
test('labels alone do not change native execution authority', () => {
  const old = group(['alice', 'bob']);
  expect(directoryAffectedUsers([old], [{ ...old, name: 'Renamed', revision: 2 }], [policy()], [policy()])).toEqual([]);
});
test('a required group-policy revision fences every previous and current affected member', () => {
  const old = group(['alice', 'bob']);
  expect(directoryAffectedUsers([old], [group(['alice', 'carol'], 2)], [policy()], [policy(2)])).toEqual(['alice', 'bob', 'carol']);
});
test('managed group deletion includes removed users but never unrelated groups', () => {
  const other = { ...group(['dave']), id: 'other', externalId: 'other-idp' };
  expect(directoryAffectedUsers([group(['alice', 'bob']), other], [other], [policy()], [])).toEqual(['alice', 'bob']);
});

function enforcementFixture() {
  const owner: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'w', role: 'member', sessionId: null, deviceId: null, botId: null };
  const base = ownerFixture(undefined, owner), services = base.services;
  serviceFixtures.push(services);
  const bot: P.Bot = { ...base.bot, id: 'b', machineId: 'm', profileId: 'lb-b' };
  services.store.put('bots', bot);
  // A permissive legacy resource reader is not execution/profile authority.
  services.auth.bot = () => bot;
  const calls: string[] = [];
  services.lemon.call = async method => { calls.push(method); throw new Error('Native receipt unavailable.'); };
  return { services, calls, owner, bot };
}

test('non-owner personal policy refresh cannot dispatch or install credentials despite legacy access', async () => {
  const f = enforcementFixture();
  for (const role of ['member', 'admin', 'owner'] as const) {
    await expect(refreshEffectivePolicy(f.services, { ...f.owner, id: 'bob', userId: 'bob', role }, ['b'])).rejects.toMatchObject({ code: 'not_found' });
  }
  expect(f.calls).toEqual([]);
  expect(f.services.store.metadata('botPolicySync:b')).toBeNull();
});

test('owner changes fence retained cross-actor invocations before installing durable policy', async () => {
  const f = enforcementFixture();
  const run: P.Run = { ...f.services.resource('run', { conversationId: f.bot.mainConversationId, botId: f.bot.id, initiatorUserId: 'bob', clientNonce: 'retained_native_operation', status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null }), id: 'old' };
  f.services.store.put('runs', run);
  // No authenticated native mapping exists for this retained run, so stop cannot be proven.
  await expect(refreshEffectivePolicy(f.services, f.owner, ['b'])).rejects.toMatchObject({ code: 'outcome_unknown' });
  expect(f.services.store.metadata('botPolicySync:b')).toMatchObject({ state: 'outcome_unknown', runIds: ['old'] });
  expect(f.calls).toEqual([]);
});

test('integration kind or forged scopes alone cannot authorize restriction management or write a native fence', async () => {
  const f = enforcementFixture();
  const member = f.services.auth.member(f.owner.userId);
  f.services.store.put('members', { ...member, role: 'owner' });
  for (const entry of [
    { kind: 'event_ingress' as const, scopes: ['event_ingress:github'], expiresAtMs: null },
    { kind: 'scim' as const, scopes: ['scim.groups'], expiresAtMs: f.services.now() - 1 },
  ]) {
    const token: P.IntegrationToken = { ...f.services.resource('integration', { name: 'Scoped management', ...entry }), id: 'integration-token' };
    f.services.store.put('integrationTokens', token);
    f.services.store.put('integrationCredentials', { id: token.id, workspaceId: f.owner.workspaceId, issuerUserId: f.owner.userId, digest: 'stored-token-digest' });
    const actor: Principal = { ...f.owner, kind: 'integration', id: token.id, role: 'member', scopes: ['scim.groups'] };
    await expect(refreshEffectivePolicy(f.services, actor, [f.bot.id], { workspace: true })).rejects.toMatchObject({ code: 'forbidden' });
    expect(f.services.store.metadata(`botPolicySync:${f.bot.id}`)).toBeNull();
    expect(f.calls).toEqual([]);
  }
});
