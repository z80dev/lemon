import { expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { directoryAffectedUsers } from '../../src/enterprise/policy';
const group = (members: string[], revision = 1): P.DirectoryGroup => ({ id: 'engineering', revision, createdAtMs: 1, updatedAtMs: revision, name: 'Engineering', source: 'oidc', externalId: 'engineering-idp', memberUserIds: members });
const policy = (revision = 1): P.GroupPolicy => ({ id: 'engineering-policy', revision, createdAtMs: 1, updatedAtMs: revision, directoryGroupId: 'engineering', productAccess: true, defaultBotIds: [], capabilityModes: {}, requiredRuleIds: [], localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, networkPolicyId: null, reviewExempt: false });

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
