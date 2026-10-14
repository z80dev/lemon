import { expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { directoryAffectedUsers } from '../../src/enterprise/policy';
import { refreshEffectivePolicy } from '../../src/enterprise/enforcement';
import type { BackendServices, Principal } from '../../src/core/services';
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
  const bot = { id: 'b', ownerUserId: 'alice', machineId: 'm', profileId: 'lb-b', revision: 1 } as P.Bot;
  const rows: Record<string, unknown[]> = { bots: [bot], runs: [] };
  const metadata = new Map<string, unknown>();
  const calls: string[] = [];
  const services = {
    store: {
      list: (collection: string, predicate?: (value: never) => boolean) => (rows[collection] ?? []).filter(value => !predicate || predicate(value as never)),
      require: (collection: string, id: string) => (rows[collection] as { id: string }[]).find(value => value.id === id),
      metadata: (key: string) => metadata.get(key) ?? null,
      setMetadata: (key: string, value: unknown) => metadata.set(key, value),
      put: (collection: string, value: { id: string }) => { const values = rows[collection] as { id: string }[]; const index = values.findIndex(item => item.id === value.id); if (index < 0) values.push(value); else values[index] = value; return value; },
    },
    auth: {
      bot: () => bot, canRead: () => true,
      member: (userId: string) => ({ userId, enabled: true, role: 'member' }),
      user: (userId: string) => ({ id: userId }),
    },
    lemon: { connected: true, methods: [], call: async (method: string) => { calls.push(method); throw new Error('Native receipt unavailable'); } },
    id: () => 'policy-operation', now: () => 100,
    update: (value: object, changes: object) => ({ ...value, ...changes }),
    events: { emit: () => undefined }, audit: () => undefined,
  } as unknown as BackendServices;
  const owner: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'w', role: 'member', sessionId: null, deviceId: null, botId: null };
  return { services, rows, metadata, calls, owner };
}

test('non-owner personal policy refresh cannot dispatch or install credentials despite legacy access', async () => {
  const f = enforcementFixture();
  for (const role of ['member', 'admin', 'owner'] as const) {
    await expect(refreshEffectivePolicy(f.services, { ...f.owner, id: 'bob', userId: 'bob', role }, ['b'])).rejects.toMatchObject({ code: 'not_found' });
  }
  expect(f.calls).toEqual([]);
  expect(f.metadata.size).toBe(0);
});

test('owner changes fence retained cross-actor invocations before installing durable policy', async () => {
  const f = enforcementFixture();
  f.rows.runs = [{ id: 'old', botId: 'b', initiatorUserId: 'bob', status: 'running' }];
  // No authenticated native mapping exists for this retained run, so stop cannot be proven.
  await expect(refreshEffectivePolicy(f.services, f.owner, ['b'])).rejects.toMatchObject({ code: 'outcome_unknown' });
  expect(f.metadata.get('botPolicySync:b')).toMatchObject({ state: 'outcome_unknown', runIds: ['old'] });
  expect(f.calls).toEqual([]);
});
