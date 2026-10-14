import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from '../../src/core/services';
import { createEmailRoutes, createEmailServices, executableAttachment } from '../../src/integrations/email';
import { closeFixture, context, emailProvider, fixture, providerMocks, route } from './channels-fixture'

function approval(services: BackendServices, principal: Principal, bot: P.Bot, state: P.ResolutionState = 'approved'): P.Approval {
  return services.resource('approval', { gate: { id: 'gate', state, targetUserId: principal.userId, expiresAtMs: services.now() + 600000, resolvedAtMs: state === 'approved' ? services.now() : null, resolvedByUserId: state === 'approved' ? principal.userId : null, revision: 1 }, entryId: 'entry', conversationId: bot.mainConversationId, botId: bot.id, runId: null, source: 'product', category: 'permissions', title: 'Claim address', description: 'Exact address', target: 'finance@mail.example.org', inputs: { providerId: 'mail', localPart: 'finance', userId: principal.userId }, policyMode: 'ask_first', review: 'not_run', ruleId: null, scope: { kind: 'once', label: 'Once', machineId: bot.machineId, machineLabel: 'Test', botId: bot.id, runId: null, origin: null, connectorId: null, consequences: ['Claim immutable address'], expiresAtMs: services.now() + 600000 } });
}
function mailbox(services: BackendServices, principal: Principal): P.EmailAccount {
  const account: P.EmailAccount = services.resource('email_account', { userId: principal.userId, provider: 'mail', address: 'finance@mail.example.org', immutableAddress: true, state: 'active', channelBindingId: null }); services.store.put('emailAccounts', account); return account;
}
function draft(services: BackendServices, principal: Principal, bot: P.Bot, account: P.EmailAccount): P.Draft {
  const result: P.Draft = services.resource('draft', { entryId: 'draft_entry', conversationId: bot.mainConversationId, botId: bot.id, ownerUserId: principal.userId, content: { kind: 'email', connectorId: account.id, from: account.address, to: ['recipient@example.org'], cc: [], bcc: [], subject: 'Reviewed subject', body: 'Reviewed body', attachmentIds: [] }, state: 'sending', sendRunId: null, providerMessageId: null, error: null }); services.store.put('drafts', result); return result;
}
describe('account-owned email provisioning and sending', () => {
  test('real availability respects reserved/local-part constraints; approval is forced exact human scope', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [emailProvider]; const mocked = providerMocks(services, url => { expect(url.pathname).toBe('/mail/addresses/availability'); expect(url.searchParams.get('localPart')).toBe('finance'); return { address: 'finance@mail.example.org', available: true, reason: null }; });
    try {
      const routes = createEmailRoutes(services); const check = route(routes, 'POST', '/v1/email/address/check');
      for (const value of ['UPPER', '-start', 'end-', 'a'.repeat(65), 'admin']) await expect(check.handler(context(services, check, principal, { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: value }))).rejects.toBeTruthy();
      const available = await check.handler(context(services, check, principal, { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: 'finance' })) as P.EmailAddressAvailability; expect(available.available).toBe(true); expect(available.address).toBe('finance@mail.example.org');
      const proposal = route(routes, 'POST', '/v1/email/address/approval'); await proposal.handler(context(services, proposal, principal, { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: 'finance', botId: bot.id }));
      expect(services.store.metadata('gateInput')).toMatchObject({ category: 'permissions', target: available.address, forceHuman: true, inputs: { providerId: 'mail', localPart: 'finance', userId: principal.userId } });
    } finally { mocked.restore(); closeFixture(services); }
  });
  test.each(['pending', 'denied', 'expired', 'cancelled'] as const)('%s gate never provisions', async state => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [emailProvider]; const gate = approval(services, principal, bot, state); services.store.put('approvals', gate); let calls = 0; const mocked = providerMocks(services, () => { calls++; throw new Error('Must not contact provider'); });
    try { const claim = route(createEmailRoutes(services), 'POST', '/v1/email/address/claim'); await expect(claim.handler(context(services, claim, principal, { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: 'finance', approvalId: gate.id }))).rejects.toMatchObject({ code: 'policy_denied' }); expect(calls).toBe(0); expect(services.store.list('emailAccounts')).toHaveLength(0); }
    finally { mocked.restore(); closeFixture(services); }
  });
  test('claim validates exact approval, creates only actual provider mailbox and one account, replays stable nonce', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [emailProvider]; const gate = approval(services, principal, bot); services.store.put('approvals', gate); let claims = 0;
    const mocked = providerMocks(services, (url, init) => { if (url.pathname.endsWith('availability')) return { address: 'finance@mail.example.org', available: true, reason: null }; expect(url.pathname).toBe('/mail/mailboxes'); expect(JSON.parse(String(init?.body))).toMatchObject({ address: gate.target, ownerId: principal.userId, idempotencyKey: 'abcdefghijklmnop' }); claims++; return { address: gate.target, provisioned: true, immutable: true }; });
    try {
      const claim = route(createEmailRoutes(services), 'POST', '/v1/email/address/claim');
      await expect(claim.handler(context(services, claim, principal, { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: 'other', approvalId: gate.id }))).rejects.toMatchObject({ code: 'policy_denied' });
      const body = { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: 'finance', approvalId: gate.id }; const account = await claim.handler(context(services, claim, principal, body)) as P.EmailAccount;
      expect(account.state).toBe('active'); expect(account.address).toBe(gate.target); expect(account.channelBindingId).toBeTruthy(); expect(await claim.handler(context(services, claim, principal, body))).toEqual(account); expect(claims).toBe(1);
      await expect(claim.handler(context(services, claim, principal, { ...body, clientNonce: 'different_nonce_16' }))).rejects.toMatchObject({ code: 'conflict' });
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('ambiguous provisioning does not create a fake mailbox or repeat the provider effect', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [emailProvider]; const gate = approval(services, principal, bot); services.store.put('approvals', gate); let claims = 0;
    const mocked = providerMocks(services, url => { if (url.pathname.endsWith('availability')) return { address: gate.target, available: true, reason: null }; claims++; throw new Error('Response lost'); });
    try { const claim = route(createEmailRoutes(services), 'POST', '/v1/email/address/claim'); const body = { clientNonce: 'abcdefghijklmnop', providerId: 'mail', localPart: 'finance', approvalId: gate.id }; await expect(claim.handler(context(services, claim, principal, body))).rejects.toMatchObject({ code: 'outcome_unknown' }); expect(services.store.list('emailAccounts')).toHaveLength(0); await expect(claim.handler(context(services, claim, principal, body))).rejects.toMatchObject({ code: 'outcome_unknown' }); expect(claims).toBe(1); }
    finally { mocked.restore(); closeFixture(services); }
  });
  test('authenticated read/search hides unsafe body and files, imports scanned safe data with stable identity', async () => {
    const { services, principal } = fixture(); services.config.operator.emailProviders = [emailProvider]; const account = mailbox(services, principal); let scan: 'virus' | 'passed' = 'virus';
    const message = () => ({ id: 'provider_message', from: 'sender@example.org', to: [account.address], subject: 'Provider mail', receivedAtMs: services.now(), authentication: 'passed', scan, text: 'Actual provider text', attachments: [{ filename: 'report.txt', mime: 'text/plain', dataBase64: Buffer.from('report').toString('base64') }, { filename: 'invoice.exe', mime: 'application/octet-stream', dataBase64: Buffer.from('MZbinary').toString('base64') }], skippedAttachmentNames: [] });
    const mocked = providerMocks(services, url => { expect(url.pathname).toContain(encodeURIComponent(account.address)); return url.pathname.endsWith('/provider_message') ? message() : { messages: [message()], indexingDelayed: true }; });
    try {
      const endpoint = route(createEmailRoutes(services), 'GET', '/v1/email/accounts/:id/messages'); const first = await endpoint.handler(context(services, endpoint, principal, undefined, { id: account.id }, 'query=Actual&sender=sender%40example.org')) as P.Page<P.EmailMessage>;
      expect(first.items[0]?.text).toBeNull(); expect(first.items[0]?.attachmentIds).toHaveLength(0); expect(first.items[0]?.skippedAttachmentNames).toContain('report.txt'); scan = 'passed';
      const second = await endpoint.handler(context(services, endpoint, principal, undefined, { id: account.id })) as P.Page<P.EmailMessage>;
      expect(second.items[0]?.id).toBe(first.items[0]?.id); expect(second.items[0]?.text).toBe('Actual provider text'); expect(second.items[0]?.attachmentIds).toHaveLength(1); expect(second.items[0]?.skippedAttachmentNames).toContain('invoice.exe');
      const third = await endpoint.handler(context(services, endpoint, principal, undefined, { id: account.id })) as P.Page<P.EmailMessage>; expect(third.items[0]?.id).toBe(second.items[0]?.id); expect(services.store.list('attachments')).toHaveLength(1);
      expect(services.store.metadata(`emailIndexing:${account.id}`)).toMatchObject({ delayed: true });
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('executable policy sniffs content and extension, never fetches arbitrary attachment URLs', () => {
    expect(executableAttachment('invoice.pdf', 'application/pdf', Buffer.from('MZbinary'))).toBe(true); expect(executableAttachment('script.txt', 'text/plain', Buffer.from('#!/bin/sh'))).toBe(true); expect(executableAttachment('program.exe', 'image/png', Buffer.from('fake'))).toBe(true); expect(executableAttachment('report.txt', 'text/plain', Buffer.from('report'))).toBe(false);
  });
  test('only frozen reviewed exact from account sends, with suppression and provider receipt dedupe', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [emailProvider]; const account = mailbox(services, principal); const outgoing = draft(services, principal, bot, account); let sent = 0;
    const mocked = providerMocks(services, (url, init) => { if (url.pathname.endsWith('/send-policy')) return { firstContact: true, newsletter: false, skipped: [], unsubscribeUrl: 'https://example.com/unsubscribe/opaque' }; sent++; expect(JSON.parse(String(init?.body))).toMatchObject({ from: account.address, subject: 'Reviewed subject', text: 'Reviewed body', idempotencyKey: outgoing.id, unsubscribe: { oneClick: true } }); return { accepted: true, messageId: 'smtp_provider_message', skipped: [] }; });
    try {
      const email = createEmailServices(services); await expect(email.sendApprovedDraft(principal, { ...outgoing, state: 'editable' })).rejects.toMatchObject({ code: 'forbidden' });
      const receipt = await email.sendApprovedDraft(principal, outgoing); expect(receipt.providerMessageId).toBe('smtp_provider_message'); expect(await email.sendApprovedDraft(principal, outgoing)).toEqual(receipt); expect(sent).toBe(1);
      const tampered = { ...outgoing, content: { ...outgoing.content, from: 'other@example.org' } } as P.Draft; await expect(email.sendApprovedDraft(principal, tampered)).rejects.toMatchObject({ code: 'conflict' });
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('all suppressed recipients and absent one-click support fail before SMTP/provider send', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [{ ...emailProvider, supportsUnsubscribe: false }]; const account = mailbox(services, principal); const outgoing = draft(services, principal, bot, account); let sent = 0;
    const mocked = providerMocks(services, url => { if (url.pathname.endsWith('/send-policy')) return { firstContact: true, newsletter: false, skipped: [], unsubscribeUrl: null }; sent++; return { accepted: true, messageId: 'wrong', skipped: [] }; });
    try { await expect(createEmailServices(services).sendApprovedDraft(principal, outgoing)).rejects.toMatchObject({ code: 'capability_unavailable' }); expect(sent).toBe(0); }
    finally { mocked.restore(); closeFixture(services); }
  });
  test('account deletion waits for actual exact provider retirement, disabling inbound immediately', async () => {
    const { services, principal, emitted } = fixture(); services.config.operator.emailProviders = [emailProvider]; const account = mailbox(services, principal); const mocked = providerMocks(services, url => { expect(url.pathname).toEndWith('/retire'); return { address: account.address, retired: true }; });
    try { await createEmailServices(services).retireUser(principal.userId); expect(services.store.require<P.EmailAccount>('emailAccounts', account.id).state).toBe('retired'); expect(emitted.every(item => JSON.stringify(item.audience) === JSON.stringify({ userIds: [principal.userId] }))).toBe(true); }
    finally { mocked.restore(); closeFixture(services); }
  });
  test('uncertain mailbox retirement is never repeated and settles from the exact address receipt after local account removal', async () => {
    const { services, principal } = fixture(); services.config.operator.emailProviders = [emailProvider]; const account = mailbox(services, principal); let posts = 0; let acknowledged = false;
    const mocked = providerMocks(services, (url, init) => { if (init?.method === 'POST') { posts++; throw new Error('Retirement acknowledgment lost'); } expect(url.pathname).toContain('/retirement/'); return { state: acknowledged ? 'retired' : 'pending', address: account.address }; });
    try {
      const email = createEmailServices(services); await expect(email.retireUser(principal.userId)).rejects.toMatchObject({ code: 'outcome_unknown' });
      await expect(email.retireUser(principal.userId)).rejects.toMatchObject({ code: 'outcome_unknown' }); expect(posts).toBe(1);
      services.store.remove('emailAccounts', account.id); services.store.remove('members', principal.userId);
      expect(await email.reconcileUserCleanup(principal.userId)).toBe(false); acknowledged = true; expect(await email.reconcileUserCleanup(principal.userId)).toBe(true); expect(posts).toBe(1);
    } finally { mocked.restore(); closeFixture(services); }
  });
  test('partial recipient suppression is privately reported and all-suppressed policy never sends', async () => {
    const { services, principal, bot } = fixture(); services.config.operator.emailProviders = [emailProvider]; const account = mailbox(services, principal); const outgoing = draft(services, principal, bot, account); let all = false; let sent = 0;
    const content: P.DraftContent = { kind: 'email', connectorId: account.id, from: account.address, to: ['allowed@example.org', 'unsubscribed@example.org'], cc: [], bcc: [], subject: 'Reviewed', body: 'Reviewed', attachmentIds: [] };
    const frozen = { ...outgoing, content }; services.store.put('drafts', frozen);
    const mocked = providerMocks(services, (url, init) => {
      if (url.pathname.endsWith('/send-policy')) return { firstContact: false, newsletter: false, skipped: [{ recipient: 'unsubscribed@example.org', reason: 'unsubscribe' }, ...(all ? [{ recipient: 'allowed@example.org', reason: 'bounce' }] : [])], unsubscribeUrl: null };
      sent++; expect(JSON.parse(String(init?.body)).to).toEqual(['allowed@example.org']); return { accepted: true, messageId: 'provider_sent', skipped: [] };
    });
    try {
      const email = createEmailServices(services); expect((await email.sendApprovedDraft(principal, frozen)).providerMessageId).toBe('provider_sent');
      const notice = services.store.list<P.TranscriptEntry>('entries')[0]; expect(notice?.kind).toBe('notice'); expect(notice?.targetedUserId).toBe(principal.userId); expect(notice && 'text' in notice ? notice.text : '').toContain('unsubscribed@example.org: unsubscribe');
      all = true; const another = { ...frozen, id: services.id('draft') }; services.store.put('drafts', another);
      await expect(email.sendApprovedDraft(principal, another)).rejects.toMatchObject({ code: 'policy_denied', details: { skippedRecipients: [{ recipient: 'unsubscribed@example.org', reason: 'unsubscribe' }, { recipient: 'allowed@example.org', reason: 'bounce' }] } }); expect(sent).toBe(1);
    } finally { mocked.restore(); closeFixture(services); }
  });
});
