import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../../src/core/services';
import { createXRoutes, createXServices } from '../../src/integrations/x';
import { IntegrationError } from '../../src/integrations/common';
import { oauthTokenClientDigest } from '../../src/integrations/oauth';
import { context, fixture, providerMocks, route } from './channels-fixture';

function configured() {
  const state = fixture(); const { services, principal, bot } = state;
  services.config.operator.xProvider = { oauth: { id: 'x-oauth', clientId: 'x-client', clientSecretRef: 'oauth', authorizeUrl: 'https://example.com/oauth/authorize', tokenUrl: 'https://example.com/oauth/token', scopes: ['tweet.read', 'users.read'], redirectUris: ['https://product.example/v1/x/oauth/callback'], allowedOrigins: ['https://example.com'] }, publicHandle: 'LemonPublic', signingSecretRef: 'signing', apiBaseUrl: 'https://example.com/x', deniedCountries: ['ZZ'], allowedMedia: ['photo'] };
  const connection: P.XConnection = services.resource('x_connection', { userId: principal.userId, externalAccountId: 'x_user', username: 'Alice', mainBotId: bot.id, enabled: true, state: 'connected', lastError: null }); services.store.put('xConnections', connection);
  services.store.setMetadata(`xCredential:${connection.id}`, services.encrypt({ accessToken: 'user-token', refreshToken: null, expiresAtMs: services.now() + 100000, scopes: ['tweet.read', 'users.read'], tokenClientDigest: oauthTokenClientDigest(services.config.operator.xProvider.oauth) }));
  return { ...state, connection };
}
function eventRequest(services: BackendServices, input: P.XIngress): Request {
  return new Request('https://product.example/v1/integrations/x/mentions', { method: 'POST', headers: { authorization: 'Bearer bridge', 'x-lemon-timestamp': String(services.now()) }, body: JSON.stringify(input) });
}
const input: P.XIngress = { deliveryId: 'x_delivery', externalAccountId: 'x_user', mentionPostId: 'post', mentionedHandle: 'LemonPublic', text: 'Untrusted provided text' };
describe('X OAuth and own explicit public mentions', () => {
  test('real OAuth binds state/S256 and actual identity; confidential exchange uses Basic and no private scopes', async () => {
    const { services, principal, bot, connection } = configured(); services.store.remove('xConnections', connection.id);
    const mocked = providerMocks((url, init) => {
      if (url.pathname === '/oauth/token') { expect(new Headers(init?.headers).get('authorization')).toStartWith('Basic '); expect(new URLSearchParams(String(init?.body)).get('code_verifier')).toBeTruthy(); return { access_token: 'real-user-token', token_type: 'bearer', expires_in: 3600, scope: 'tweet.read users.read' }; }
      if (url.pathname.endsWith('/2/users/me')) return { data: { id: new Headers(init?.headers).get('authorization') === 'Bearer public-bot-token' ? 'public_bot' : 'actual_external_user', username: new Headers(init?.headers).get('authorization') === 'Bearer public-bot-token' ? 'LemonPublic' : 'VerifiedAlice' } };
      throw new Error('Unexpected provider request');
    });
    try {
      const routes = createXRoutes(services); const connect = route(routes, 'POST', '/v1/x/connections'); const pending = await connect.handler(context(services, connect, principal, { clientNonce: 'abcdefghijklmnop', mainBotId: bot.id, redirectUri: 'https://product.example/return' })) as P.XConnectResult;
      expect(pending.connection.state).toBe('pending'); expect(pending.connection.externalAccountId).toBeNull(); expect(pending.connection.username).toBeNull(); const authorization = new URL(pending.authorizationUrl); expect(authorization.searchParams.get('code_challenge_method')).toBe('S256');
      const callback = route(routes, 'GET', '/v1/x/oauth/callback'); const query = new URLSearchParams({ state: authorization.searchParams.get('state')!, code: 'real-code' }).toString(); const connected = await callback.handler(context(services, callback, null, undefined, {}, query)) as P.XConnection;
      expect(connected.externalAccountId).toBe('actual_external_user'); expect(connected.username).toBe('VerifiedAlice'); expect(connected.state).toBe('connected'); expect(JSON.stringify(connected)).not.toContain('real-user-token');
      await expect(callback.handler(context(services, callback, null, undefined, {}, query))).rejects.toMatchObject({ code: 'conflict' });
    } finally { mocked.restore(); services.store.db.close(); }
  });
  test('accepted private run precedes actual public confirmation; duplicate signed delivery neither runs nor posts twice', async () => {
    const { services, principal, bot, submissions } = configured(); let posts = 0;
    const mocked = providerMocks((url, init) => {
      if (url.pathname.endsWith('/2/users/me')) return { data: { id: 'public_bot', username: 'LemonPublic' } };
      if (url.pathname.endsWith('/2/tweets/post')) return { data: { id: 'post', author_id: 'x_user', text: '@LemonPublic actual provider text', created_at: new Date(services.now()).toISOString(), entities: { mentions: [{ username: 'LemonPublic' }] } }, includes: { tweets: [{ id: 'quoted', author_id: 'other_user', text: 'untrusted contextual text', created_at: new Date(services.now()).toISOString() }] } };
      if (url.pathname.endsWith('/moderation/check')) return { allowed: true, reason: null, country: 'US', usageAllowed: true, mediaAllowed: true };
      if (url.pathname.endsWith('/2/tweets')) { expect(submissions).toHaveLength(1); expect(submissions[0]?.principal.userId).toBe(principal.userId); expect(submissions[0]?.conversationId).toBe(bot.mainConversationId); expect(JSON.parse(String(init?.body))).toMatchObject({ reply: { in_reply_to_tweet_id: 'post' } }); posts++; return { data: { id: 'confirmed_post' } }; }
      throw new Error('Unexpected request');
    });
    try {
      const endpoint = route(createXRoutes(services), 'POST', '/v1/integrations/x/mentions'); const invoke = () => endpoint.handler(context(services, endpoint, null, undefined, {}, '', eventRequest(services, input)));
      const receipt = await invoke() as P.IntegrationIngressReceipt; expect(receipt.accepted).toBe(true); expect(receipt.runId).toBeTruthy(); expect(submissions[0]?.message.text).toContain('actual provider text'); expect(submissions[0]?.message.text).toContain('untrusted contextual text'); expect(submissions[0]?.message.text).not.toContain('Untrusted provided text');
      expect(await invoke()).toEqual(receipt); expect(posts).toBe(1); expect(submissions).toHaveLength(1);
    } finally { mocked.restore(); services.store.db.close(); }
  });
  test.each(['wrong_author', 'incidental_thread', 'region', 'moderation', 'provider_usage', 'spend', 'media', 'disabled'] as const)('%s does not start work or post accepted confirmation', async reason => {
    const { services, connection, submissions } = configured(); let posted = 0;
    if (reason === 'disabled') services.store.put('xConnections', { ...connection, enabled: false });
    if (reason === 'spend') services.integrations.admission = async () => { throw new IntegrationError('policy_denied', 'Budget exhausted.'); };
    const mocked = providerMocks(url => {
      if (url.pathname.endsWith('/2/users/me')) return { data: { id: 'public_bot', username: 'LemonPublic' } };
      if (url.pathname.endsWith('/2/tweets/post')) return { data: { id: 'post', author_id: reason === 'wrong_author' ? 'someone_else' : 'x_user', text: 'actual text', created_at: new Date(services.now()).toISOString(), entities: { mentions: reason === 'incidental_thread' ? [] : [{ username: 'LemonPublic' }] }, ...(reason === 'media' ? { attachments: { media_keys: ['video_key'] } } : {}) }, includes: { media: reason === 'media' ? [{ media_key: 'video_key', type: 'video' }] : [] } };
      if (url.pathname.endsWith('/moderation/check')) return { allowed: reason !== 'moderation', reason: reason === 'moderation' ? 'Provider refused' : null, country: reason === 'region' ? 'ZZ' : 'US', usageAllowed: reason !== 'provider_usage', mediaAllowed: true };
      if (url.pathname.endsWith('/2/tweets')) { posted++; return { data: { id: 'wrong' } }; }
      throw new Error('Unexpected request');
    });
    try { const endpoint = route(createXRoutes(services), 'POST', '/v1/integrations/x/mentions'); const receipt = await endpoint.handler(context(services, endpoint, null, undefined, {}, '', eventRequest(services, input))) as P.IntegrationIngressReceipt; expect(receipt.accepted).toBe(false); expect(receipt.status).toBe('ignored'); expect(submissions).toHaveLength(0); expect(posted).toBe(0); }
    finally { mocked.restore(); services.store.db.close(); }
  });
  test('uncertain public confirmation retains accepted run and reconciles actual reply without redispatch', async () => {
    const { services, submissions } = configured(); let posts = 0; let timelineVisible = false;
    const mocked = providerMocks(url => {
      if (url.pathname.endsWith('/2/users/me')) return { data: { id: 'public_bot', username: 'LemonPublic' } };
      if (url.pathname.endsWith('/2/tweets/post')) return { data: { id: 'post', author_id: 'x_user', text: '@LemonPublic work', created_at: new Date(services.now()).toISOString(), entities: { mentions: [{ username: 'LemonPublic' }] } } };
      if (url.pathname.endsWith('/moderation/check')) return { allowed: true, reason: null, country: 'US', usageAllowed: true, mediaAllowed: true };
      if (url.pathname.endsWith('/2/tweets')) { posts++; throw new Error('Acknowledgment lost'); }
      if (url.pathname.endsWith('/2/users/public_bot/tweets')) return { data: timelineVisible ? [{ id: 'actual_confirmation', text: 'Accepted. Your connected personal Bot is working privately in Lemon Bot.', created_at: new Date(services.now()).toISOString(), referenced_tweets: [{ type: 'replied_to', id: 'post' }] }] : [] };
      throw new Error('Unexpected request');
    });
    try {
      const endpoint = route(createXRoutes(services), 'POST', '/v1/integrations/x/mentions'); const invoke = () => endpoint.handler(context(services, endpoint, null, undefined, {}, '', eventRequest(services, input)));
      const unknown = await invoke() as P.IntegrationIngressReceipt; expect(unknown.accepted).toBe(true); expect(unknown.status).toBe('outcome_unknown'); expect(unknown.runId).toBeTruthy();
      await createXServices(services).reconcile(); expect((await invoke() as P.IntegrationIngressReceipt).status).toBe('outcome_unknown');
      timelineVisible = true; await createXServices(services).reconcile(); expect((await invoke() as P.IntegrationIngressReceipt).status).toBe('accepted'); expect(posts).toBe(1); expect(submissions).toHaveLength(1);
    } finally { mocked.restore(); services.store.db.close(); }
  });
  test('public token must belong to actual configured handle; missing credential never fabricates confirmation', async () => {
    const { services, submissions } = configured(); const mocked = providerMocks(() => ({ data: { id: 'foreign', username: 'WrongHandle' } }));
    try { const endpoint = route(createXRoutes(services), 'POST', '/v1/integrations/x/mentions'); await expect(endpoint.handler(context(services, endpoint, null, undefined, {}, '', eventRequest(services, input)))).rejects.toMatchObject({ code: 'capability_unavailable' }); expect(submissions).toHaveLength(0); }
    finally { mocked.restore(); services.store.db.close(); }
  });
  test('account cleanup attempts both token scopes once and settles only actual read-only provider receipts', async () => {
    const { services, principal, connection } = configured(); const provider = services.config.operator.xProvider!;
    services.store.setMetadata(`xCredential:${connection.id}`, services.encrypt({ accessToken: 'user-token', refreshToken: 'refresh-token', expiresAtMs: null, scopes: provider.oauth.scopes, tokenClientDigest: oauthTokenClientDigest(provider.oauth) }));
    let dispatched = 0; let acknowledged = false;
    const mocked = providerMocks((url, init) => {
      if (url.pathname.endsWith('/2/oauth2/revoke')) { dispatched++; expect(new Headers(init?.headers).get('x-lemon-operation-id')).toBeTruthy(); throw new Error('Provider acknowledgment lost'); }
      if (url.pathname.endsWith('/2/users/me')) return { data: { id: 'public_bot', username: 'LemonPublic' } };
      const operation = services.store.require<{ tokenType: string }>('xRevocations', decodeURIComponent(url.pathname.split('/').at(-1)!));
      return { state: acknowledged ? 'revoked' : 'pending', tokenType: operation.tokenType };
    });
    try {
      const x = createXServices(services); await expect(x.retireUser(principal.userId)).rejects.toMatchObject({ code: 'outcome_unknown' }); expect(dispatched).toBe(2);
      await expect(x.retireUser(principal.userId)).rejects.toMatchObject({ code: 'outcome_unknown' }); expect(dispatched).toBe(2);
      services.store.remove('members', principal.userId); services.store.remove('xConnections', connection.id);
      expect(await x.reconcileUserCleanup(principal.userId)).toBe(false); acknowledged = true; expect(await x.reconcileUserCleanup(principal.userId)).toBe(true); expect(dispatched).toBe(2);
      expect(services.store.metadata(`xCredential:${connection.id}`)).toBeNull();
    } finally { mocked.restore(); services.store.db.close(); }
  });
  test('installed grant cannot be revoked using a reassigned OAuth client', async () => {
    const { services, principal } = configured(); services.config.operator.xProvider!.oauth.clientId = 'different-client'; let dispatched = 0;
    const mocked = providerMocks(() => { dispatched++; throw new Error('Must not dispatch old credential'); });
    try { await expect(createXServices(services).retireUser(principal.userId)).rejects.toMatchObject({ code: 'capability_unavailable' }); expect(dispatched).toBe(0); }
    finally { mocked.restore(); services.store.db.close(); }
  });
  test('CRC supports actual provider challenges without issuing a chosen-JSON webhook MAC', async () => {
    const { services } = configured(); const endpoint = route(createXRoutes(services), 'GET', '/v1/integrations/x/mentions');
    try {
      const result = await endpoint.handler(context(services, endpoint, null, undefined, {}, 'crc_token=actual-provider-challenge')) as { response_token: string }; expect(result.response_token).toStartWith('sha256=');
      await expect(endpoint.handler(context(services, endpoint, null, undefined, {}, `crc_token=${encodeURIComponent(JSON.stringify({ tweet_create_events: [] }))}`))).rejects.toMatchObject({ code: 'invalid_request' });
    } finally { services.store.db.close(); }
  });
});
