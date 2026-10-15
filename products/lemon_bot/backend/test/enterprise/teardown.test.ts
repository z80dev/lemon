import { expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { ApiError } from '../../src/core/errors';
import { createProviderTeardownServices, prepareProviderTeardown } from '../../src/enterprise/teardown';
import { identityFixture } from './identity.test';

test('teardown preserves original private targets after user removal and never replays uncertain effects', async () => {
  const f = identityFixture();
  try {
    const s = f.services, userId = f.principal.userId;
    const account = s.resource('mail', { userId, provider: 'mail-provider', address: 'original@example.com', immutable: true, state: 'active' as const, claimedAtMs: s.now(), retiredAtMs: null });
    s.store.put('emailAccounts', account);
    const operationId = 'account_teardown_original';
    s.store.setMetadata(`accountDeletion:${userId}`, { operationId, nonce: 'delete-original' });
    const initial = prepareProviderTeardown(s, userId, operationId);
    expect(initial).toHaveLength(1); expect(JSON.stringify(initial)).not.toContain(account.address);
    s.store.remove('emailAccounts', account.id); s.store.remove('users', userId);
    let effects = 0, observed = 0;
    const service = createProviderTeardownServices(s, {
      execute: async () => { effects++; throw new ApiError('outcome_unknown', 'Acknowledgment lost.', false); },
      observe: async receipt => {
        observed++;
        const original = s.decrypt<{ account: { id: string; address: string } }>(receipt.encryptedBinding);
        expect(original.account).toMatchObject({ id: account.id, address: account.address });
        return { state: 'outcome_unknown', errorCode: 'outcome_unknown', updatedAtMs: s.now() };
      },
    });
    await expect(service.deprovisionUser(userId)).rejects.toMatchObject({ code: 'outcome_unknown', retrySafe: false });
    const once = effects;
    await expect(service.deprovisionUser(userId)).rejects.toMatchObject({ code: 'outcome_unknown' });
    await service.observeAccountTeardown(operationId);
    expect(effects).toBe(once); expect(observed).toBeGreaterThan(1);
  } finally { f.close(); }
});

test('in-flight OAuth exchange is a cleanup target before any issued credential exists', async () => {
  const f = identityFixture();
  try {
    const s = f.services, userId = f.principal.userId;
    s.store.put('oauthExchangeOperations', { id: 'flow-original', userId, providerId: 'x-client', resourceId: 'x-original', callbackPath: '/v1/x/oauth/callback', tokenClientDigest: 'original-client-digest', state: 'dispatching', createdAtMs: s.now() });
    const targets = prepareProviderTeardown(s, userId, 'delete-inflight');
    expect(targets).toHaveLength(1); expect(targets[0]).toMatchObject({ kind: 'x', providerId: 'x-client', state: 'pending' });
    let effects = 0;
    const service = createProviderTeardownServices(s, { execute: async () => { effects++; }, observe: async () => ({ state: 'outcome_unknown', updatedAtMs: s.now(), errorCode: 'outcome_unknown' }) });
    const status = await service.observeAccountTeardown('delete-inflight');
    expect(status[0]?.state).toBe('outcome_unknown'); expect(effects).toBe(0);
    expect(JSON.stringify(status)).not.toContain('original-client-digest');
  } finally { f.close(); }
});

test('provider failure does not skip other cleanup domains or fabricate completion', async () => {
  const f = identityFixture();
  try {
    const s = f.services, userId = f.principal.userId, order: string[] = [];
    s.store.setMetadata(`accountDeletion:${userId}`, { operationId: 'delete-all', nonce: 'delete-all-nonce' });
    s.store.put('oidcProviderSessions', { id: 'original-session', userId, providerId: 'original-idp', encryptedIDToken: s.encrypt('private-token-hint') });
    const service = createProviderTeardownServices(s, {
      execute: async (_user, kind) => { order.push(kind); if (kind === 'email') throw new ApiError('capability_unavailable', 'Configure mailbox retirement.'); },
      observe: async () => ({ state: 'failed' as P.AccountCleanupState, updatedAtMs: s.now(), errorCode: 'capability_unavailable' }),
    });
    await expect(service.deprovisionUser(userId)).rejects.toMatchObject({ code: 'outcome_unknown' });
    expect(order).toEqual(['email', 'x', 'channel', 'oidc', 'connector']);
    expect((await service.observeAccountTeardown('delete-all'))[0]).toMatchObject({ state: 'failed', errorCode: 'capability_unavailable' });
  } finally { f.close(); }
});
