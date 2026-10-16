import { describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Store } from '../../src/core/store';
import { providerAuthorityGeneration, providerCompletionCollection, type ProviderCompletion } from '../../src/core/provider_completion';

/** Isolated, nonsecret SQLite records only; no OAuth, secret store or user config. */
describe('durable provider completion reconciliation and revocation generations', () => {
  test('reopened unknown completions never block durable authority invalidation or re-pairing', () => {
    const root = mkdtempSync(join(tmpdir(), 'lemon-provider-journal-'));
    let store = new Store(join(root, 'product.sqlite'));
    try {
      const rows: { collection: string; value: { id: string } & Record<string, unknown> }[] = [
        { collection: 'users', value: { id: 'owner' } },
        { collection: 'members', value: { id: 'membership', userId: 'owner', enabled: true, role: 'owner' } },
        { collection: 'workspaces', value: { id: 'workspace', enabled: true, ownerUserId: 'owner' } },
        { collection: 'authSessions', value: { id: 'session', userId: 'owner', deviceId: 'phone', expiresAtMs: null, lastSeenAtMs: 1 } },
        { collection: 'sessionSecrets', value: { id: 'session', revoked: false } },
        { collection: 'devices', value: { id: 'phone', userId: 'owner', name: 'Mock phone' } },
        { collection: 'machines', value: { id: 'machine', nodeId: 'mock', ownerUserId: 'owner', status: 'online' } },
        { collection: 'directoryGroups', value: { id: 'directory', memberUserIds: ['owner'] } },
        { collection: 'groupPolicies', value: { id: 'policy', directoryGroupId: 'directory', productAccess: true } },
      ];
      for (const row of rows) store.put(row.collection, row.value);
      store.setMetadata('workspaceId', 'workspace');
      store.setMetadata('governance', { groupAccess: 'all' });
      const generation = providerAuthorityGeneration(store);
      const completion: ProviderCompletion = {
        id: 'mock-completion', userId: 'owner', sessionId: 'session', deviceId: 'phone',
        workspaceId: 'workspace', machineId: 'machine', authorityGeneration: generation, params: {
          completionId: 'mock-completion', targetId: 'node:mock', nodeId: 'mock',
          providerId: 'openai_codex', loginId: 'mock-login', ownerId: 'opaque-owner',
          sessionId: 'opaque-session', challengeNonce: '', commit: false,
        },
      };
      store.put(providerCompletionCollection, completion);
      store.close(); store = new Store(join(root, 'product.sqlite'));
      expect(providerAuthorityGeneration(store)).toBe(generation);
      expect(store.list(providerCompletionCollection)).toEqual([completion]);
      store.put('authSessions', { ...rows[3]!.value, lastSeenAtMs: 2 });
      store.put('devices', { ...rows[5]!.value, name: 'Renamed phone' });
      store.setMetadata('unrelated', true);
      expect(providerAuthorityGeneration(store)).toBe(generation);
      for (const row of rows) {
        const before = providerAuthorityGeneration(store);
        store.remove(row.collection, row.value.id);
        expect(providerAuthorityGeneration(store)).toBeGreaterThan(before);
      }
      store.setMetadata('workspaceId', 'replacement');
      store.setMetadata('governance', { groupAccess: 'selected' });
      store.setMetadata('accountDeletion:owner', { status: 'completed' });
      // Restoring authority advances its generation again, never reviving a pin.
      for (const row of rows) store.put(row.collection, row.value);
      const revokedGeneration = providerAuthorityGeneration(store);
      expect(revokedGeneration).toBeGreaterThan(generation);
      expect(store.list(providerCompletionCollection)).toEqual([completion]);
      store.close(); store = new Store(join(root, 'product.sqlite'));
      expect(providerAuthorityGeneration(store)).toBe(revokedGeneration);
      expect(store.metadata<number>('providerAuthority:session:session')).toBeGreaterThan(generation);
      expect(store.metadata<number>('providerAuthority:device:phone')).toBeGreaterThan(generation);
      expect(store.metadata<number>('providerAuthority:user:owner')).toBeGreaterThan(generation);
    } finally {
      store.close(); rmSync(root, { recursive: true, force: true });
    }
  });

  test('authority generation and local revocation roll back together, independent of corrupt journals', () => {
    const store = new Store(':memory:');
    try {
      store.put('devices', { id: 'phone', userId: 'owner' });
      store.put(providerCompletionCollection, { id: 'corrupt' });
      const generation = providerAuthorityGeneration(store);
      expect(() => store.transaction(() => { store.remove('devices', 'phone'); throw new Error('rollback'); })).toThrow('rollback');
      expect(providerAuthorityGeneration(store)).toBe(generation);
      expect(store.get('devices', 'phone')).toEqual({ id: 'phone', userId: 'owner' });
      store.remove('devices', 'phone');
      expect(store.get('devices', 'phone')).toBeNull();
      expect(providerAuthorityGeneration(store)).toBeGreaterThan(generation);
      expect(store.list(providerCompletionCollection)).toEqual([{ id: 'corrupt' }]);
    } finally { store.close(); }
  });
});
