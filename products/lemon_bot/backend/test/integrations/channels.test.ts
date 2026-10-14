import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../../src/core/services';
import { createChannelRoutes, createChannelServices } from '../../src/integrations/channels';
import { hmac } from '../../src/integrations/channel-security';
import { closeFixture, context, fixture, providerMocks, route, slackProvider } from './channels-fixture'

function installed() {
  const state = fixture(); const { services, principal, bot } = state; services.config.operator.channelProviders = [slackProvider];
  services.store.put('bots', { ...bot, visibility: 'team', published: true });
  services.store.put('channelAccounts', { id: 'slack_account', providerId: slackProvider.id, teamId: 'T1', botUserId: 'B1', appId: 'A1', token: services.encrypt('account-token'), installerUserId: 'U1', productUserId: principal.userId, botId: bot.id });
  const binding: P.ChannelBinding = services.resource('channel', { botId: bot.id, ownerUserId: principal.userId, adapter: 'slack', accountId: 'slack_account', target: 'C1', enabled: true, state: 'connected', capabilities: slackProvider.capabilities, lastError: null }); services.store.put('channelBindings', binding);
  return { ...state, binding };
}
function signedSlack(services: BackendServices, value: unknown): Request {
  const raw = JSON.stringify(value); const seconds = String(services.now() / 1000);
  return new Request('https://product.example/v1/integrations/slack/events', { method: 'POST', headers: { 'x-slack-request-timestamp': seconds, 'x-slack-signature': 'v0=' + hmac('private-signing-key', `v0:${seconds}:${raw}`) }, body: raw });
}
describe('Slack app installation and verified channel identities', () => {
  test('installation uses state/S256/form exchange and actual Slack admin/account verification', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.channelProviders = [slackProvider]; services.store.put('bots', { ...bot, visibility: 'team', published: true });
    const calls: string[] = []; const mocked = providerMocks(services, (url, init) => {
      calls.push(url.pathname); const form = new URLSearchParams(String(init?.body));
      if (url.pathname === '/oauth/token') { expect(form.get('grant_type')).toBe('authorization_code'); expect(form.get('code_verifier')).toBeTruthy(); expect(form.get('redirect_uri')).toBe('https://product.example/v1/channels/oauth/callback'); return { ok: true, token_type: 'bot', access_token: 'installed-token', team: { id: 'T1' }, authed_user: { id: 'U1' }, bot_user_id: 'B1', app_id: 'A1' }; }
      if (url.pathname.endsWith('/auth.test')) return { ok: true, team_id: 'T1', user_id: 'B1' };
      if (url.pathname.endsWith('/users.info')) return { ok: true, user: { id: 'U1', is_admin: true, deleted: false } };
      if (url.pathname.endsWith('/conversations.open')) return { ok: true, channel: { id: 'D1' } };
      if (url.pathname.endsWith('/chat.postMessage')) return { ok: true, ts: '1800000000.1' };
      throw new Error('Unexpected provider call ' + url.pathname);
    });
    try {
      const routes = createChannelRoutes(services); const setup = route(routes, 'POST', '/v1/channels/setup');
      const pending = await setup.handler(context(services, setup, principal, { clientNonce: 'abcdefghijklmnop', botId: bot.id, adapter: 'slack', providerId: slackProvider.id, accountLabel: 'Team', redirectUri: 'https://product.example/return' })) as P.ChannelSetupFlow;
      expect(pending.state).toBe('pending'); const authorize = new URL(pending.authorizationUrl!); expect(authorize.searchParams.get('code_challenge_method')).toBe('S256');
      const callback = route(routes, 'GET', '/v1/channels/oauth/callback'); const query = new URLSearchParams({ state: authorize.searchParams.get('state')!, code: 'provider-code' }).toString();
      const connected = await callback.handler(context(services, callback, null, undefined, {}, query)) as P.ChannelSetupFlow;
      expect(connected.state).toBe('connected'); expect(connected.channelBindingId).toBeTruthy(); expect(calls).toContain('/api/users.info');
      const stored = services.store.list<{ token: string }>('channelAccounts')[0]; expect(stored?.token).not.toContain('installed-token'); expect(services.store.list('channelPrincipalLinks')).toHaveLength(0);
      await expect(callback.handler(context(services, callback, null, undefined, {}, query))).rejects.toMatchObject({ code: 'conflict' });
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('non-admin installation awaits actual Slack admin; no fake connected binding', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.channelProviders = [slackProvider]; services.store.put('bots', { ...bot, visibility: 'team', published: true });
    const mocked = providerMocks(services, url => url.pathname === '/oauth/token' ? { ok: true, token_type: 'bot', access_token: 'installed-token', team: { id: 'T1' }, authed_user: { id: 'U1' }, bot_user_id: 'B1', app_id: 'A1' } : url.pathname.endsWith('auth.test') ? { ok: true, team_id: 'T1', user_id: 'B1' } : url.pathname.endsWith('users.info') ? { ok: true, user: { id: 'U1', is_admin: false } } : { ok: true, revoked: true });
    try {
      const routes = createChannelRoutes(services); const setup = route(routes, 'POST', '/v1/channels/setup'); const pending = await setup.handler(context(services, setup, principal, { clientNonce: 'abcdefghijklmnop', botId: bot.id, adapter: 'slack', providerId: slackProvider.id, accountLabel: 'Team', redirectUri: 'https://product.example/return' })) as P.ChannelSetupFlow;
      const callback = route(routes, 'GET', '/v1/channels/oauth/callback'); const connected = await callback.handler(context(services, callback, null, undefined, {}, new URLSearchParams({ state: new URL(pending.authorizationUrl!).searchParams.get('state')!, code: 'provider-code' }).toString())) as P.ChannelSetupFlow;
      expect(connected.state).toBe('awaiting_admin'); expect(services.store.list('channelBindings')).toHaveLength(0);
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('product-start code must arrive from signed own DM; final proof cannot map arbitrary user or be reused', async () => {
    const { services, principal, binding, submissions } = installed(); const mocked = providerMocks(services, () => ({ ok: true, ts: '1800000000.2', channel: { id: 'D1' } }));
    try {
      const routes = createChannelRoutes(services); const start = route(routes, 'POST', '/v1/channels/principal-links/start'); const poll = route(routes, 'GET', '/v1/channels/principal-links/flows/:id'); const link = route(routes, 'POST', '/v1/channels/principal-links'); const ingress = route(routes, 'POST', '/v1/integrations/slack/events');
      const flow = await start.handler(context(services, start, principal, { clientNonce: 'abcdefghijklmnop', channelBindingId: binding.id })) as P.ChannelLinkFlow;
      expect(flow.externalUserId).toBeNull(); expect(flow.verificationCode).toBeNull();
      const body = { type: 'event_callback', team_id: 'T1', api_app_id: 'A1', event_id: 'E_link', event: { type: 'message', user: 'U_own', channel: 'D1', channel_type: 'im', ts: '1800000000.1', text: flow.linkCode } };
      const verified = await ingress.handler(context(services, ingress, null, undefined, {}, '', signedSlack(services, body))) as P.IntegrationIngressReceipt; expect(verified.accepted).toBe(false); expect(submissions).toHaveLength(0);
      const proof = await poll.handler(context(services, poll, principal, undefined, { id: flow.id })) as P.ChannelLinkFlow; expect(proof.state).toBe('verified'); expect(proof.externalUserId).toBe('U_own'); expect(proof.verificationCode).toBeTruthy();
      await expect(link.handler(context(services, link, principal, { clientNonce: 'abcdefghijklmnop', channelBindingId: binding.id, externalUserId: 'U_foreign', verificationCode: proof.verificationCode }))).rejects.toMatchObject({ code: 'unauthenticated' });
      const linked = await link.handler(context(services, link, principal, { clientNonce: 'abcdefghijklmnop', channelBindingId: binding.id, externalUserId: 'U_own', verificationCode: proof.verificationCode })) as P.ChannelPrincipalLink;
      expect(linked.userId).toBe(principal.userId); expect(linked.verified).toBe(true);
      await expect(link.handler(context(services, link, principal, { clientNonce: 'different_nonce_16', channelBindingId: binding.id, externalUserId: 'U_own', verificationCode: proof.verificationCode }))).rejects.toMatchObject({ code: 'unauthenticated' });
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('unlinked actor never spends owner; mapped DMs share private context; mentions/own thread replies dedupe', async () => {
    const { services, principal, binding, submissions } = installed(); const mocked = providerMocks(services, () => ({ ok: true, channel: { id: 'D1' }, ts: '1800000000.9' }));
    try {
      const ingress = route(createChannelRoutes(services), 'POST', '/v1/integrations/slack/events');
      const deliver = (deliveryId: string, text: string, channel = 'D1', type = 'message', thread?: string) => { const body = { type: 'event_callback', team_id: 'T1', api_app_id: 'A1', event_id: deliveryId, event: { type, user: 'U1', channel, channel_type: channel.startsWith('D') ? 'im' : 'channel', ts: '1800000000.1', thread_ts: thread, text } }; return ingress.handler(context(services, ingress, null, undefined, {}, '', signedSlack(services, body))); };
      expect((await deliver('E_unlinked', 'Do work') as P.IntegrationIngressReceipt).accepted).toBe(false); expect(submissions).toHaveLength(0);
      services.store.put('channelPrincipalLinks', services.resource('link', { channelBindingId: binding.id, externalUserId: 'U1', userId: principal.userId, verified: true }));
      await deliver('E_dm1', 'first'); await deliver('E_dm2', 'second'); expect(submissions[0]?.conversationId).toBe(submissions[1]?.conversationId);
      expect((await deliver('E_top', 'incidental text', 'C1') as P.IntegrationIngressReceipt).accepted).toBe(false);
      const mention = await deliver('E_mention', '<@B1> review', 'C1', 'app_mention') as P.IntegrationIngressReceipt; expect(mention.accepted).toBe(true);
      await deliver('E_reply', 'thread reply', 'C1', 'message', '1800000000.1'); expect(submissions[2]?.conversationId).toBe(submissions[3]?.conversationId);
      await deliver('E_reply', 'thread reply', 'C1', 'message', '1800000000.1'); expect(submissions).toHaveLength(4); expect(submissions.every(item => item.principal.userId === principal.userId)).toBe(true);
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('handoff cannot change actor/return thread or expose a personal Bot in shared Slack', async () => {
    const { services, principal, binding, bot } = installed(); services.store.put('channelPrincipalLinks', services.resource('link', { channelBindingId: binding.id, externalUserId: 'U1', userId: principal.userId, verified: true }));
    const channels = createChannelServices(services); const receipt = await channels.channelIngress({ principal, botId: bot.id, channelBindingId: binding.id, externalThreadId: 'C1:1800000000.1', text: 'task', clientNonce: 'abcdefghijklmnop' });
    const source = services.store.require<P.Conversation>('conversations', receipt.runs[0]!.conversationId); const personal = { ...bot, visibility: 'personal' as const };
    expect(() => channels.assertChannelHandoff(principal, source, personal, source.id)).toThrow(); expect(() => channels.assertChannelHandoff(principal, source, services.auth.bot(principal, bot.id), bot.mainConversationId)).toThrow();
    const privateRoom = services.store.require<P.Conversation>('conversations', bot.mainConversationId);
    expect(() => channels.assertChannelHandoff(principal, privateRoom, services.auth.bot(principal, bot.id), source.id)).toThrow();
    closeFixture(services);
  });
  test('removal performs real uninstall, failure disables ingress and reports cleanup', async () => {
    const { services, principal, binding, bot } = installed(); const mocked = providerMocks(services, url => { expect(url.pathname).toEndWith('apps.uninstall'); throw new Error('provider timeout'); });
    try { const endpoint = route(createChannelRoutes(services), 'DELETE', '/v1/channels/:id'); await expect(endpoint.handler(context(services, endpoint, principal, { clientNonce: 'abcdefghijklmnop', revision: binding.revision }, { id: binding.id }))).rejects.toMatchObject({ code: 'outcome_unknown' }); const retained = services.store.require<P.ChannelBinding>('channelBindings', binding.id); expect(retained.enabled).toBe(false); expect(retained.lastError).toContain('cleanup'); expect(services.store.get('bots', bot.id)).toBeTruthy(); }
    finally { mocked.restore(); closeFixture(services); }
  });
});
