import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { IntegrationError, assertActiveAccount } from './common';
import { providerRequest } from './channels';
import { dedupeIngress, id, ignored, nonce, ownedBot, ownedBinding, parse, principalFor, providerResult, rawBody, requireUser, runEventRoutine, senderMatches, verifyIngress } from './channel-security';

const localPart = z.string().min(1).max(64).regex(/^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/);
const addressBody = z.strictObject({ clientNonce: nonce, providerId: id, localPart });
const mailAddress = z.string().max(320).regex(/^[^\s<>@,;\r\n]+@[^\s<>@,;\r\n]+\.[^\s<>@,;\r\n]+$/);
const attachmentData = z.strictObject({ filename: z.string().min(1).max(256), mime: z.string().min(1).max(128), dataBase64: z.string().max(14 * 1024 * 1024) });
const providerMail = z.strictObject({ id, from: mailAddress, to: z.array(mailAddress).max(50), subject: z.string().max(4096), receivedAtMs: z.number().int().nonnegative(), authentication: z.enum(['passed', 'failed', 'unknown']), scan: z.enum(['passed', 'spam', 'virus', 'pending']), text: z.string().max(65536).nullable(), attachments: z.array(attachmentData).max(10), skippedAttachmentNames: z.array(z.string().max(256)).max(100) });
interface MailBinding { id: string; accountId: string; providerMessageId: string }
interface ClaimReservation { id: string; nonce: string; approvalId: string; providerId: string; botId: string; address: string; accountId: string; state: 'reserved' | 'active' | 'retired' | 'failed'; error: string | null }
interface SendReceipt { id: string; accountId: string; receipt: { providerMessageId: string | null; runId: string | null } | null }
interface EmailRetirement { id: string; userId: string; providerId: string; accountId: string; address: string; immutable: boolean; claimOperationId: string | null; state: 'reserved' | 'retired' | 'failed' | 'outcome_unknown' }
interface EmailSuppression { id: string; accountId: string; recipient: string; reason: 'unsubscribe' | 'bounce' | 'complaint' }
const executableExtension = /\.(?:exe|com|bat|cmd|scr|ps1|vbs|vbe|js|jse|msi|msp|dll|sh|bash|zsh|app|pkg|dmg|jar|lnk|iso|hta|reg|wsf|py|rb|pl)$/i;
export function executableAttachment(filename: string, mime: string, bytes: Uint8Array): boolean {
  return executableExtension.test(filename) || /(?:x-executable|x-msdownload|x-sh|x-shellscript|java-archive|x-mach-binary)/i.test(mime) || bytes[0] === 0x4d && bytes[1] === 0x5a || bytes[0] === 0x7f && bytes[1] === 0x45 && bytes[2] === 0x4c && bytes[3] === 0x46 || bytes[0] === 0x23 && bytes[1] === 0x21 || ['feedface','feedfacf','cefaedfe','cffaedfe','cafebabe'].includes(Buffer.from(bytes.subarray(0, 4)).toString('hex'));
}
export async function emailPolicy(services: BackendServices, principal: Principal): Promise<void> {
  assertActiveAccount(services, principal.userId);
  const governance = services.store.list<P.Governance>('governance')[0] ?? services.store.metadata<P.Governance>('governance');
  if (!governance?.emailEnabled || !(await services.integrations.effectivePolicy(principal)).productAccess) throw new IntegrationError('policy_denied', 'Email is disabled by workspace access policy.');
}
function providerFor(services: BackendServices, providerId: string): P.EmailProviderConfig {
  const provider = services.config.operator.emailProviders.find(item => item.id === providerId);
  if (!provider) throw new IntegrationError('capability_unavailable', 'Configure an email provisioning, mailbox, and delivery provider.');
  return provider;
}
function mailboxBot(services: BackendServices, principal: Principal, account: P.EmailAccount, botId?: string): P.Bot | null {
  if (account.userId !== principal.userId) throw new IntegrationError('forbidden', 'Mailbox operations require its authenticated owner.');
  if (!account.channelBindingId) return botId ? ownedBot(services, principal, botId) : null;
  const binding = services.store.require<P.ChannelBinding>('channelBindings', account.channelBindingId);
  if (binding.accountId !== account.id || binding.adapter !== 'email' || binding.target !== account.address || botId && binding.botId !== botId) throw new IntegrationError('forbidden', 'Mailbox must match its fixed Bot binding.');
  return ownedBinding(services, principal, binding);
}
function checkAddress(provider: P.EmailProviderConfig, value: string): string {
  parse(localPart, value);
  if (provider.reservedNames.includes(value)) throw new IntegrationError('conflict', 'This mailbox name is reserved by the provider.');
  return `${value}@${provider.domain}`;
}
function throttle(services: BackendServices, principal: Principal, action: string): void {
  const key = `emailRate:${principal.userId}:${action}`; const times = services.store.metadata<number[]>(key) ?? [];
  const recent = times.filter(time => time > services.now() - 60000);
  if (recent.length >= 10) throw new IntegrationError('rate_limited', 'Email provisioning is limited to ten requests per minute.');
  services.store.setMetadata(key, [...recent, services.now()]);
}
async function checkAvailable(services: BackendServices, principal: Principal, provider: P.EmailProviderConfig, value: string): Promise<P.EmailAddressAvailability> {
  const address = checkAddress(provider, value);
  if (services.store.list<P.EmailAccount>('emailAccounts', account => account.userId === principal.userId && account.state !== 'retired').length) return { providerId: provider.id, address, available: false, reason: 'One account-owned mailbox is already claimed.', immutable: provider.immutableAddresses };
  const result = parse(z.strictObject({ address: mailAddress, available: z.boolean(), reason: z.string().max(256).nullable() }), await providerRequest(services, provider.provisioningBaseUrl, `addresses/availability?localPart=${encodeURIComponent(value)}`, await services.secret(provider.provisioningSecretRef)));
  if (result.address !== address) throw new IntegrationError('upstream_unavailable', 'Provisioning provider returned a different mailbox address.');
  return { providerId: provider.id, address, available: result.available, reason: result.reason, immutable: provider.immutableAddresses };
}
async function importMail(services: BackendServices, principal: Principal, account: P.EmailAccount, value: z.infer<typeof providerMail>): Promise<P.EmailMessage> {
  const key = services.mutations.digest([account.id, value.id]); const existingId = services.store.metadata<string>(`emailMessageKey:${key}`);
  const existing = existingId ? services.store.get<P.EmailMessage>('emailMessages', existingId) : null;
  const digest = services.mutations.digest(value);
  if (existing && services.store.metadata<string>(`emailMessageDigest:${key}`) === digest) return existing;
  const safe = value.authentication === 'passed' && value.scan === 'passed';
  if (!safe && existing) for (const attachmentId of existing.attachmentIds) {
    const attachment = services.store.get<P.Attachment>('attachments', attachmentId);
    if (attachment?.ownerUserId === principal.userId && attachment.state === 'ready') { const quarantined = services.update(attachment, { state: 'deleted' as const }); services.store.put('attachments', quarantined); services.events.emit('attachment.upserted', quarantined, { userIds: [principal.userId] }); }
  }
  const attachmentIds: string[] = []; const skipped = [...value.skippedAttachmentNames]; let total = 0;
  if (safe) for (const file of value.attachments) {
    const bytes = Buffer.from(file.dataBase64, 'base64');
    if (bytes.toString('base64') !== file.dataBase64 || bytes.byteLength > 10 * 1024 * 1024 || total + bytes.byteLength > 25 * 1024 * 1024 || executableAttachment(file.filename, file.mime, bytes)) { skipped.push(file.filename); continue; }
    total += bytes.byteLength;
    const attachment = await services.attachments.create(principal, bytes, { clientNonce: services.mutations.digest([key, file.filename, digest]), filename: file.filename, mime: file.mime, purpose: 'message' });
    attachmentIds.push(attachment.id);
  } else skipped.push(...value.attachments.map(file => file.filename));
  const fields = { accountId: account.id, from: value.from, to: value.to, subject: value.subject, receivedAtMs: value.receivedAtMs, authentication: value.authentication, scan: value.scan, text: safe ? value.text : null, attachmentIds, skippedAttachmentNames: [...new Set(skipped)] };
  const message: P.EmailMessage = existing ? services.update(existing, fields) : services.resource('email_message', fields);
  services.store.put('emailMessages', message); services.store.put('emailMessageBindings', { id: message.id, accountId: account.id, providerMessageId: value.id }); services.store.setMetadata(`emailMessageKey:${key}`, message.id);
  services.store.setMetadata(`emailMessageDigest:${key}`, digest);
  return message;
}
async function retireAddress(services: BackendServices, operation: EmailRetirement): Promise<void> {
  const previous = services.store.get<EmailRetirement>('emailRetirements', operation.id);
  if (previous?.state === 'retired') return;
  if (previous) throw new IntegrationError('outcome_unknown', 'Mailbox retirement is already reserved; query its provider receipt without redispatch.', false);
  const provider = providerFor(services, operation.providerId);
  services.store.put('emailRetirements', operation);
  try {
    const result = providerResult(z.strictObject({ retired: z.literal(true), address: mailAddress }), await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(operation.address)}/retire`, await services.secret(provider.provisioningSecretRef), 'POST', { idempotencyKey: operation.id, immutableNamespace: operation.immutable, ...(operation.claimOperationId ? { claimOperationId: operation.claimOperationId } : {}) }), true);
    if (result.address !== operation.address) throw new IntegrationError('outcome_unknown', 'Mailbox retirement acknowledgment did not match.', false);
    services.store.put('emailRetirements', { ...operation, state: 'retired' });
  } catch (error) {
    services.store.put('emailRetirements', { ...operation, state: error instanceof IntegrationError && error.retrySafe ? 'failed' : 'outcome_unknown' });
    services.store.setMetadata(`emailCleanup:${operation.accountId}`, { required: true, outcome: 'outcome_unknown', atMs: services.now() }); throw error;
  }
}
async function retirePendingClaim(services: BackendServices, pending: ClaimReservation): Promise<void> {
  const provider = providerFor(services, pending.providerId);
  await retireAddress(services, { id: services.mutations.digest(['retire_pending', pending.accountId]), userId: pending.id, providerId: provider.id, accountId: pending.accountId, address: pending.address, immutable: provider.immutableAddresses, claimOperationId: pending.nonce, state: 'reserved' });
  services.store.put('emailClaimReservations', { ...pending, state: 'retired' });
}

export interface EmailServices {
  inventory(): P.EmailProviderInfo[];
  canReadResource(principal: Principal, collection: string, value: unknown): boolean | undefined;
  reconcileUserCleanup(userId: string): Promise<boolean>;
  reconcile(): Promise<void>;
  sendApprovedDraft(principal: Principal, draft: P.Draft): Promise<{ providerMessageId: string | null; runId: string | null }>;
  retireUser(userId: string): Promise<void>;
}
const emailInstances = new WeakMap<BackendServices, EmailServices>();
export function createEmailServices(services: BackendServices): EmailServices {
  const existing = emailInstances.get(services); if (existing) return existing;
  const integration: EmailServices = {
    inventory: (): P.EmailProviderInfo[] => services.config.operator.emailProviders.map(provider => ({ id: provider.id, kind: 'email', label: `${provider.domain} — ${provider.id}`, domain: provider.domain, immutableAddresses: provider.immutableAddresses, supportsProvisioning: true, supportsUnsubscribe: provider.supportsUnsubscribe, configured: true, prerequisites: [], capabilities: ['provisioning', 'authenticated_mailbox', 'scan_metadata', 'reviewed_provider_delivery', ...(provider.supportsUnsubscribe ? ['one_click_unsubscribe'] : [])] })),
    reconcileUserCleanup: async (userId: string): Promise<boolean> => {
      let complete = true;
      for (const operation of services.store.list<EmailRetirement>('emailRetirements', item => item.userId === userId && item.state !== 'retired')) {
        const provider = providerFor(services, operation.providerId);
        const result = providerResult(z.strictObject({ state: z.enum(['pending', 'retired', 'failed']), address: mailAddress }), await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(operation.address)}/retirement/${encodeURIComponent(operation.id)}`, await services.secret(provider.provisioningSecretRef)));
        if (result.address !== operation.address) throw new IntegrationError('upstream_unavailable', 'Mailbox retirement receipt belongs to a different address.');
        if (result.state !== 'retired') { complete = false; if (result.state === 'failed') services.store.put('emailRetirements', { ...operation, state: 'failed' }); continue; }
        services.store.put('emailRetirements', { ...operation, state: 'retired' }); services.store.setMetadata(`emailCleanup:${operation.accountId}`, null);
        const account = services.store.get<P.EmailAccount>('emailAccounts', operation.accountId);
        if (account && account.address === operation.address) { const retired = services.update(account, { state: 'retired' as const }); services.store.put('emailAccounts', retired); services.events.emit('email_account.upserted', retired, { userIds: [userId] }); }
        const reservation = services.store.get<ClaimReservation>('emailClaimReservations', userId);
        if (reservation?.accountId === operation.accountId) services.store.put('emailClaimReservations', { ...reservation, state: 'retired' });
      }
      return complete;
    },
    canReadResource: (principal: Principal, collection: string, value: unknown): boolean | undefined => {
      if (!['emailAccounts', 'emailMessages'].includes(collection)) return undefined;
      const resource = z.object({ id, ...(collection === 'emailAccounts' ? { userId: id } : { accountId: id }) }).passthrough().safeParse(value);
      if (!resource.success || !services.auth.member(principal.userId).enabled) return false;
      const account = services.store.get<P.EmailAccount>('emailAccounts', collection === 'emailAccounts' ? resource.data.id : String(resource.data.accountId));
      if (!account || account.userId !== principal.userId) return false;
      try { mailboxBot(services, principal, account); return true; } catch { return false; }
    },
    reconcile: async (): Promise<void> => {
      for (const reservation of services.store.list<ClaimReservation>('emailClaimReservations', item => item.state === 'reserved')) {
        const configuredBot = services.store.get<P.Bot>('bots', reservation.botId);
        if (!configuredBot || configuredBot.ownerUserId !== reservation.id) continue;
        if (!services.store.metadata(`accountDeletion:${reservation.id}`)) ownedBot(services, principalFor(services, reservation.id), reservation.botId);
        const provider = providerFor(services, reservation.providerId);
        const operation = providerResult(z.strictObject({ state: z.enum(['pending', 'succeeded', 'failed']), address: mailAddress, immutable: z.boolean(), reason: z.string().max(256).nullable() }), await providerRequest(services, provider.provisioningBaseUrl, `operations/${encodeURIComponent(reservation.nonce)}`, await services.secret(provider.provisioningSecretRef)));
        if (operation.address !== reservation.address || operation.immutable !== provider.immutableAddresses) throw new IntegrationError('upstream_unavailable', 'Provider operation identity did not match the reserved mailbox.');
        if (operation.state === 'pending') continue;
        if (operation.state === 'failed') { services.store.put('emailClaimReservations', { ...reservation, state: 'failed', error: 'Provider confirmed mailbox provisioning failed.' }); continue; }
        if (services.store.metadata(`accountDeletion:${reservation.id}`)) { await retirePendingClaim(services, reservation); continue; }
        assertActiveAccount(services, reservation.id, true);
        if (services.store.require<ClaimReservation>('emailClaimReservations', reservation.id).state !== 'reserved') continue;
        const principal = principalFor(services, reservation.id); const bot = ownedBot(services, principal, reservation.botId);
        const channel: P.ChannelBinding = services.resource('channel', { botId: bot.id, ownerUserId: principal.userId, adapter: 'email', accountId: reservation.accountId, target: reservation.address, enabled: true, state: 'connected', capabilities: { inbound: true, outbound: true, events: ['email_received'] }, lastError: null });
        const account: P.EmailAccount = { ...services.resource('email_account', { userId: principal.userId, provider: provider.id, address: reservation.address, immutableAddress: operation.immutable, state: 'active' as const, channelBindingId: channel.id, indexingDelayed: null, indexingMeasuredAtMs: null }), id: reservation.accountId };
        services.store.transaction(() => { services.store.put('channelBindings', channel); services.store.put('emailAccounts', account); services.store.put('emailClaimReservations', { ...reservation, state: 'active', error: null }); });
        services.events.emit('email_account.upserted', account, { userIds: [principal.userId] }); services.events.emit('channel.upserted', channel, { userIds: [principal.userId] });
      }
      for (const delivery of services.store.list<SendReceipt>('emailSendReceipts', item => !item.receipt)) {
        const account = services.store.require<P.EmailAccount>('emailAccounts', delivery.accountId); const provider = providerFor(services, account.provider);
        const draft = services.store.get<P.Draft>('drafts', delivery.id);
        if (!draft || draft.ownerUserId !== account.userId || services.store.get<P.Bot>('bots', draft.botId)?.ownerUserId !== account.userId) continue;
        mailboxBot(services, principalFor(services, account.userId), account, draft.botId);
        const result = providerResult(z.strictObject({ state: z.enum(['pending', 'accepted', 'rejected']), messageId: id.nullable() }), await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/deliveries/${encodeURIComponent(delivery.id)}`, await services.secret(provider.provisioningSecretRef)));
        if (result.state === 'pending') continue;
        if (result.state === 'accepted' && result.messageId) {
          services.store.put('emailSendReceipts', { ...delivery, receipt: { providerMessageId: result.messageId, runId: null } });
          if (draft && ['sending', 'outcome_unknown'].includes(draft.state)) { const sent = services.update(draft, { state: 'sent' as const, providerMessageId: result.messageId, error: null }); services.store.put('drafts', sent); services.events.emit('draft.upserted', sent, { userIds: [draft.ownerUserId] }); }
        } else if (result.state === 'rejected') {
          services.store.remove('emailSendReceipts', delivery.id);
          if (draft && ['sending', 'outcome_unknown'].includes(draft.state)) { const failed = services.update(draft, { state: 'failed' as const, error: 'Provider confirmed this email was not accepted; review a new explicit send.' }); services.store.put('drafts', failed); services.events.emit('draft.upserted', failed, { userIds: [draft.ownerUserId] }); }
        }
      }
    },
    sendApprovedDraft: async (principal: Principal, draft: P.Draft): Promise<{ providerMessageId: string | null; runId: string | null }> => {
      await emailPolicy(services, principal);
      if (draft.ownerUserId !== principal.userId || draft.state !== 'sending' || draft.content.kind !== 'email') throw new IntegrationError('forbidden', 'Explicit account-owner DraftSend is required.');
      const persisted = services.store.require<P.Draft>('drafts', draft.id);
      if (persisted.state !== 'sending' || persisted.ownerUserId !== principal.userId || persisted.botId !== draft.botId || persisted.conversationId !== draft.conversationId || persisted.revision !== draft.revision || services.mutations.digest(persisted.content) !== services.mutations.digest(draft.content)) throw new IntegrationError('conflict', 'Approved draft content or ownership changed.');
      ownedBot(services, principal, draft.botId); const conversation = services.auth.conversation(principal, draft.conversationId);
      if (conversation.kind === 'group' || conversation.kind === 'channel') throw new IntegrationError('forbidden', 'Outward email approval must be in a private conversation.');
      const content = draft.content;
      const account = services.store.get<P.EmailAccount>('emailAccounts', content.connectorId) ?? services.store.list<P.EmailAccount>('emailAccounts', item => item.channelBindingId === content.connectorId)[0];
      if (!account || account.userId !== principal.userId || account.state !== 'active' || content.from !== account.address) throw new IntegrationError('forbidden', 'From address must be the exact active account-owned mailbox.');
      mailboxBot(services, principal, account, draft.botId);
      if (conversation.ownerUserId !== principal.userId) throw new IntegrationError('forbidden', 'Draft context must belong to the Bot owner.');
      const reservation = services.store.get<SendReceipt>('emailSendReceipts', draft.id);
      if (reservation?.receipt) return reservation.receipt;
      if (reservation) throw new IntegrationError('outcome_unknown', 'This draft delivery is already reserved; inspect provider delivery before another send.', false);
      const provider = providerFor(services, account.provider); const recipients = [...content.to, ...content.cc, ...content.bcc];
      if (!recipients.length || recipients.length > 50) throw new IntegrationError('invalid_request', 'Email requires one to fifty total To/Cc/Bcc recipients.');
      recipients.forEach(value => parse(mailAddress, value));
      if (/[\r\n]/.test(content.subject)) throw new IntegrationError('invalid_request', 'Email subject cannot contain header delimiters.');
      if (content.attachmentIds.length > 10) throw new IntegrationError('too_large', 'Email supports at most ten attachments.');
      const files = []; let total = 0;
      for (const attachmentId of content.attachmentIds) {
        const attachment = services.auth.attachment(principal, attachmentId); const bytes = await services.attachments.bytes(attachment.id);
        if (bytes.byteLength > 10 * 1024 * 1024 || (total += bytes.byteLength) > 25 * 1024 * 1024) throw new IntegrationError('too_large', 'Email attachments exceed the ten MiB each / twenty-five MiB total limits.');
        if (executableAttachment(attachment.filename, attachment.mime, bytes)) throw new IntegrationError('unsupported_media', 'Executable email attachments are blocked.');
        files.push({ filename: attachment.filename, mime: attachment.mime, dataBase64: Buffer.from(bytes).toString('base64') });
      }
      const compliance = parse(z.strictObject({ firstContact: z.boolean(), newsletter: z.boolean(), skipped: z.array(z.strictObject({ recipient: mailAddress, reason: z.enum(['unsubscribe', 'bounce', 'complaint']) })).max(50), unsubscribeUrl: z.string().url().nullable() }), await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/send-policy`, await services.secret(provider.provisioningSecretRef), 'POST', { recipients, subject: content.subject, body: content.body }));
      if ((compliance.firstContact || compliance.newsletter) && recipients.length !== 1) throw new IntegrationError('policy_denied', 'First-contact and newsletter email require a single recipient.');
      if ((compliance.firstContact || compliance.newsletter) && (!provider.supportsUnsubscribe || !compliance.unsubscribeUrl)) throw new IntegrationError('capability_unavailable', 'Provider one-click unsubscribe is required for this message.');
      if (compliance.unsubscribeUrl && new URL(compliance.unsubscribeUrl).protocol !== 'https:') throw new IntegrationError('upstream_unavailable', 'Provider unsubscribe link must use HTTPS.');
      const suppressions = services.store.list<EmailSuppression>('emailSuppressions', item => item.accountId === account.id);
      const skipped = [...compliance.skipped, ...suppressions.filter(item => recipients.some(recipient => recipient.toLowerCase() === item.recipient.toLowerCase())).map(item => ({ recipient: item.recipient, reason: item.reason }))];
      const allowed = (addresses: string[]) => addresses.filter(address => !skipped.some(item => item.recipient.toLowerCase() === address.toLowerCase()));
      if (![...allowed(content.to), ...allowed(content.cc), ...allowed(content.bcc)].length) throw new IntegrationError('policy_denied', 'All recipients were suppressed by unsubscribe, bounce or complaint policy.', true, { skippedRecipients: skipped.map(item => ({ recipient: item.recipient, reason: item.reason })) });
      await emailPolicy(services, principal);
      if (services.store.require<P.EmailAccount>('emailAccounts', account.id).state !== 'active') throw new IntegrationError('policy_denied', 'Mailbox was disabled before provider delivery.');
      services.store.transaction(() => { if (services.store.get<SendReceipt>('emailSendReceipts', draft.id)) throw new IntegrationError('outcome_unknown', 'This draft was already reserved by another sender.', false); services.store.put('emailSendReceipts', { id: draft.id, accountId: account.id, receipt: null } satisfies SendReceipt); });
      let acknowledgment: unknown;
      try { acknowledgment = await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/messages/send`, await services.secret(provider.provisioningSecretRef), 'POST', { idempotencyKey: draft.id, from: account.address, to: allowed(content.to), cc: allowed(content.cc), bcc: allowed(content.bcc), subject: content.subject, text: content.body, attachments: files, unsubscribe: compliance.unsubscribeUrl ? { url: compliance.unsubscribeUrl, oneClick: true } : null }); }
      catch (error) { if (error instanceof IntegrationError && error.retrySafe) services.store.remove('emailSendReceipts', draft.id); throw error; }
      const result = providerResult(z.strictObject({ accepted: z.literal(true), messageId: id, skipped: z.array(z.strictObject({ recipient: mailAddress, reason: z.string().max(256) })).max(50) }), acknowledgment, true);
      const receipt = { providerMessageId: result.messageId, runId: null }; services.store.put('emailSendReceipts', { id: draft.id, accountId: account.id, receipt } satisfies SendReceipt);
      const omitted = [...skipped, ...result.skipped];
      if (omitted.length) {
        services.store.setMetadata(`emailSendSkipped:${draft.id}`, omitted);
        services.entry(principal, draft.conversationId, { kind: 'notice', severity: 'warning', actor: { kind: 'system', id: null, displayName: 'Email delivery' }, targetedUserId: principal.userId, text: `Email provider accepted the message; these recipients were skipped:\n${omitted.map(item => `${item.recipient}: ${item.reason}`).join('\n')}`, requestId: null });
      }
      services.audit(principal, 'email.send', draft.id, 'succeeded', { skippedRecipientCount: omitted.length });
      return receipt;
    },
    retireUser: async (userId: string): Promise<void> => {
      let failure: unknown = null;
      const pending = services.store.get<ClaimReservation>('emailClaimReservations', userId);
      if (pending?.state === 'reserved') try { await retirePendingClaim(services, pending); } catch (error) { failure = error; }
      const accounts = services.store.list<P.EmailAccount>('emailAccounts', account => account.userId === userId && account.state !== 'retired');
      for (const account of accounts) {
        const disabled = services.update(account, { state: 'disabled' as const }); services.store.put('emailAccounts', disabled); services.events.emit('email_account.upserted', disabled, { userIds: [userId] });
        if (account.channelBindingId) { const channel = services.store.get<P.ChannelBinding>('channelBindings', account.channelBindingId); if (channel) services.store.put('channelBindings', services.update(channel, { enabled: false, state: 'disconnected' })); }
        try {
          await retireAddress(services, { id: services.mutations.digest(['retire', account.id]), userId, providerId: account.provider, accountId: account.id, address: account.address, immutable: account.immutableAddress, claimOperationId: null, state: 'reserved' });
          const retired = services.update(disabled, { state: 'retired' as const }); services.store.put('emailAccounts', retired); services.events.emit('email_account.upserted', retired, { userIds: [userId] });
          const reservation = services.store.get<ClaimReservation>('emailClaimReservations', userId); if (reservation) services.store.put('emailClaimReservations', { ...reservation, state: 'retired' });
        } catch (error) { failure ??= error; services.store.setMetadata(`emailCleanup:${account.id}`, { required: true, outcome: 'outcome_unknown', atMs: services.now() }); services.audit(null, 'email.retire', account.id, 'outcome_unknown', { cleanupRequired: true }); }
      }
      if (failure) throw failure;
    },
  };
  emailInstances.set(services, integration); return integration;
}
export function createEmailRoutes(services: BackendServices): Route[] {
  const routes: Route[] = [
    { method: 'GET', path: '/v1/email/providers', auth: 'member', handler: () => createEmailServices(services).inventory() },
    { method: 'POST', path: '/v1/email/address/check', auth: 'member', handler: async context => { const principal = requireUser(context); await emailPolicy(services, principal); const body = parse(addressBody, context.body); throttle(services, principal, 'check'); return checkAvailable(services, principal, providerFor(services, body.providerId), body.localPart); } },
    { method: 'POST', path: '/v1/email/address/approval', auth: 'member', handler: async context => {
      const principal = requireUser(context); await emailPolicy(services, principal); const body = parse(addressBody.extend({ botId: id }), context.body); const bot = services.auth.bot(principal, body.botId);
      if (bot.ownerUserId !== principal.userId) throw new IntegrationError('forbidden', 'Mailbox approval requires an owned Bot.');
      throttle(services, principal, 'approval'); const available = await checkAvailable(services, principal, providerFor(services, body.providerId), body.localPart);
      if (!available.available) throw new IntegrationError('conflict', 'Requested mailbox is unavailable.');
      return services.gates.create<P.Approval>(principal, 'approval', { conversationId: bot.mainConversationId, botId: bot.id, category: 'permissions', title: 'Claim account-owned email address', description: available.immutable ? 'Provision this immutable address; deleting your account retires it through the provider.' : 'Provision this address; lifecycle and retirement follow the configured provider policy.', target: available.address, inputs: { providerId: body.providerId, localPart: body.localPart, userId: principal.userId }, expiresInMs: 600000, forceHuman: true });
    } },
    { method: 'POST', path: '/v1/email/address/claim', auth: 'member', handler: async context => {
      const principal = requireUser(context); await emailPolicy(services, principal); const body = parse(addressBody.extend({ approvalId: id }), context.body); const provider = providerFor(services, body.providerId); const address = checkAddress(provider, body.localPart);
      const approval = services.store.require<P.Approval>('approvals', body.approvalId);
      if (approval.category !== 'permissions' || approval.gate.targetUserId !== principal.userId || approval.gate.state !== 'approved' || approval.gate.resolvedByUserId !== principal.userId || approval.gate.expiresAtMs <= services.now() || approval.target !== address || approval.inputs.providerId !== body.providerId || approval.inputs.localPart !== body.localPart || approval.inputs.userId !== principal.userId) throw new IntegrationError('policy_denied', 'Approve the exact provider, mailbox name and account before claiming.');
      const bot = services.auth.bot(principal, approval.botId); if (bot.ownerUserId !== principal.userId) throw new IntegrationError('forbidden', 'Approved mailbox Bot is not owned by this account.');
      throttle(services, principal, 'claim');
      const previous = services.store.get<ClaimReservation>('emailClaimReservations', principal.userId);
      if (previous && !['retired', 'failed'].includes(previous.state)) {
        if (previous.nonce === body.clientNonce && previous.approvalId === body.approvalId && previous.address === address && previous.state === 'active') return services.store.require<P.EmailAccount>('emailAccounts', previous.accountId);
        throw new IntegrationError(previous.state === 'reserved' ? 'outcome_unknown' : 'conflict', previous.state === 'reserved' ? 'Mailbox claim is reserved; reconcile its provider outcome before another claim.' : 'One account-owned mailbox is already claimed.', previous.state !== 'reserved');
      }
      if (services.store.metadata<boolean>(`emailApprovalUsed:${approval.id}`)) throw new IntegrationError('conflict', 'Mailbox approval was already consumed.');
      const available = await checkAvailable(services, principal, provider, body.localPart); if (!available.available) throw new IntegrationError('conflict', 'Mailbox is no longer available.');
      const accountId = services.id('email_account');
      services.store.transaction(() => {
        const current = services.store.get<ClaimReservation>('emailClaimReservations', principal.userId);
        if (current && !['retired', 'failed'].includes(current.state) || services.store.list<P.EmailAccount>('emailAccounts', item => item.userId === principal.userId && item.state !== 'retired').length) throw new IntegrationError('conflict', 'Another mailbox claim is already reserved or active.');
        services.store.put('emailClaimReservations', { id: principal.userId, nonce: body.clientNonce, approvalId: approval.id, providerId: provider.id, botId: bot.id, address, accountId, state: 'reserved', error: null } satisfies ClaimReservation); services.store.setMetadata(`emailApprovalUsed:${approval.id}`, true);
      });
      context.nonceResourceIds.push(accountId);
      const result = providerResult(z.strictObject({ address: mailAddress, provisioned: z.literal(true), immutable: z.boolean() }), await providerRequest(services, provider.provisioningBaseUrl, 'mailboxes', await services.secret(provider.provisioningSecretRef), 'POST', { address, localPart: body.localPart, ownerId: principal.userId, idempotencyKey: body.clientNonce }), true);
      if (result.address !== address || result.immutable !== provider.immutableAddresses) throw new IntegrationError('outcome_unknown', 'Provider claim acknowledgment does not match the approved mailbox.', false);
      if (services.store.metadata(`accountDeletion:${principal.userId}`)) { await retirePendingClaim(services, services.store.require<ClaimReservation>('emailClaimReservations', principal.userId)); assertActiveAccount(services, principal.userId, true); }
      const current = services.store.require<ClaimReservation>('emailClaimReservations', principal.userId);
      if (current.state === 'active' && current.nonce === body.clientNonce) return services.store.require<P.EmailAccount>('emailAccounts', current.accountId);
      if (current.state !== 'reserved' || current.nonce !== body.clientNonce) throw new IntegrationError('outcome_unknown', 'The mailbox reservation changed during provisioning.', false);
      const channel: P.ChannelBinding = services.resource('channel', { botId: bot.id, ownerUserId: principal.userId, adapter: 'email', accountId, target: address, enabled: true, state: 'connected', capabilities: { inbound: true, outbound: true, events: ['email_received'] }, lastError: null });
      const account: P.EmailAccount = { ...services.resource('email_account', { userId: principal.userId, provider: provider.id, address, immutableAddress: provider.immutableAddresses, state: 'active' as const, channelBindingId: channel.id, indexingDelayed: null, indexingMeasuredAtMs: null }), id: accountId };
      services.store.transaction(() => { services.store.put('channelBindings', channel); services.store.put('emailAccounts', account); services.store.put('emailClaimReservations', { id: principal.userId, nonce: body.clientNonce, approvalId: approval.id, providerId: provider.id, botId: bot.id, address, accountId, state: 'active', error: null } satisfies ClaimReservation); });
      services.events.emit('email_account.upserted', account, { userIds: [principal.userId] }); services.events.emit('channel.upserted', channel, { userIds: [principal.userId] }); return account;
    } },
    { method: 'GET', path: '/v1/email/accounts', auth: 'member', handler: async context => { const principal = requireUser(context); await emailPolicy(services, principal); return services.page(context, services.store.list<P.EmailAccount>('emailAccounts', account => createEmailServices(services).canReadResource(principal, 'emailAccounts', account) === true)); } },
    { method: 'GET', path: '/v1/email/accounts/:id/messages', auth: 'member', handler: async context => {
      const principal = requireUser(context); await emailPolicy(services, principal); const account = services.store.require<P.EmailAccount>('emailAccounts', context.params.id!);
      if (account.userId !== principal.userId) throw new IntegrationError('not_found', 'Own email account was not found.');
      if (account.state !== 'active') throw new IntegrationError('policy_denied', 'Mailbox is not active.');
      mailboxBot(services, principal, account);
      const provider = providerFor(services, account.provider); const query = context.query.get('query'); const sender = context.query.get('sender');
      if (query && query.length > 512 || sender && !mailAddress.safeParse(sender).success) throw new IntegrationError('invalid_request', 'Invalid mailbox search.');
      const options = { binding: { accountId: account.id, query, sender } };
      const after = services.pageAfter(context, options);
      const limit = parse(z.coerce.number().int().min(1).max(200), context.query.get('limit') ?? 50);
      const params = new URLSearchParams(); if (query) params.set('query', query); if (sender) params.set('sender', sender); params.set('limit', String(limit + 1));
      if (after) { const separator = after.indexOf(':'); if (separator < 1) throw new IntegrationError('invalid_request', 'Mailbox page cursor is invalid.'); params.set('beforeReceivedAtMs', after.slice(0, separator)); params.set('beforeMessageId', after.slice(separator + 1)); }
      const result = providerResult(z.strictObject({ messages: z.array(providerMail).max(201), indexingDelayed: z.boolean() }), await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/messages?${params}`, await services.secret(provider.provisioningSecretRef)));
      const indexed = services.update(account, { indexingDelayed: result.indexingDelayed, indexingMeasuredAtMs: services.now() });
      services.store.put('emailAccounts', indexed); services.events.emit('email_account.upserted', indexed, { userIds: [principal.userId] });
      services.store.setMetadata(`emailIndexing:${account.id}`, { delayed: result.indexingDelayed, measuredAtMs: indexed.indexingMeasuredAtMs });
      const messages = []; for (const message of result.messages) messages.push(await importMail(services, principal, account, message));
      return services.page(context, messages, { ...options, key: message => `${String(message.receivedAtMs).padStart(16, '0')}:${services.store.require<MailBinding>('emailMessageBindings', message.id).providerMessageId}` });
    } },
    { method: 'GET', path: '/v1/email/messages/:id', auth: 'member', handler: async context => {
      const principal = requireUser(context); await emailPolicy(services, principal); const message = services.store.require<P.EmailMessage>('emailMessages', context.params.id!); const account = services.store.require<P.EmailAccount>('emailAccounts', message.accountId);
      if (account.userId !== principal.userId) throw new IntegrationError('not_found', 'Own email message was not found.');
      if (account.state !== 'active') throw new IntegrationError('policy_denied', 'Mailbox is disabled or retired.');
      mailboxBot(services, principal, account);
      const binding = services.store.require<MailBinding>('emailMessageBindings', message.id); const provider = providerFor(services, account.provider);
      const value = parse(providerMail, await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/messages/${encodeURIComponent(binding.providerMessageId)}`, await services.secret(provider.provisioningSecretRef)));
      if (value.id !== binding.providerMessageId) throw new IntegrationError('upstream_unavailable', 'Provider message identity changed.');
      return importMail(services, principal, account, value);
    } },
    { method: 'POST', path: '/v1/integrations/email/events', auth: 'public', mutation: false, body: 'none', handler: async context => {
      const raw = await rawBody(context.request); let value: unknown; try { value = JSON.parse(raw); } catch { throw new IntegrationError('invalid_request', 'Invalid email gateway event.'); }
      const body = parse(z.strictObject({ providerId: id, deliveryId: id, event: z.enum(['email_received', 'unsubscribe', 'bounce', 'complaint']), address: mailAddress, timestampMs: z.number().int().nonnegative(), message: providerMail.optional(), messageId: id.optional(), recipient: mailAddress.optional() }), value);
      if (context.params.providerId && context.params.providerId !== body.providerId) throw new IntegrationError('unauthenticated', 'Mailbox provider does not match the registered delivery path.');
      const provider = providerFor(services, body.providerId); await verifyIngress(services, context.request, raw, provider.id, 'email', provider.signingSecretRef, 300000, body);
      if (Math.abs(services.now() - body.timestampMs) > 300000) throw new IntegrationError('unauthenticated', 'Old mailbox events are not backfilled.');
      const configuredAccount = services.store.list<P.EmailAccount>('emailAccounts', item => item.provider === provider.id && item.address === body.address && item.state === 'active')[0];
      if (!configuredAccount) return ignored('Mailbox is disabled or retired.');
      const configuredPrincipal = principalFor(services, configuredAccount.userId);
      mailboxBot(services, configuredPrincipal, configuredAccount);
      await emailPolicy(services, configuredPrincipal);
      return dedupeIngress(services, provider.id, body.deliveryId, body, async () => {
        const account = services.store.list<P.EmailAccount>('emailAccounts', item => item.provider === provider.id && item.address === body.address && item.state === 'active')[0]; if (!account) return ignored('Mailbox is disabled or retired.');
        if (body.event !== 'email_received') {
          if (!body.recipient) throw new IntegrationError('invalid_request', 'Suppression event requires a recipient.');
          services.store.put('emailSuppressions', { id: services.mutations.digest([account.id, body.recipient.toLowerCase()]), accountId: account.id, recipient: body.recipient.toLowerCase(), reason: body.event } satisfies EmailSuppression); return ignored('Recipient suppression was recorded.');
        }
        if (!body.message && !body.messageId) throw new IntegrationError('invalid_request', 'Incoming mail event requires a provider message identity.');
        const principal = principalFor(services, account.userId);
        const value = body.messageId ? providerResult(providerMail, await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/messages/${encodeURIComponent(body.messageId)}`, await services.secret(provider.provisioningSecretRef))) : body.message!;
        if (body.messageId && value.id !== body.messageId) throw new IntegrationError('upstream_unavailable', 'Mailbox provider message identity did not match the signed event.');
        const message = await importMail(services, principal, account, value); await emailPolicy(services, principal);
        if (message.authentication !== 'passed' || message.scan !== 'passed') return ignored('Only authenticated, scanned mail may trigger routines.');
        const channel = account.channelBindingId ? services.store.get<P.ChannelBinding>('channelBindings', account.channelBindingId) : null;
        if (!channel?.enabled || channel.state !== 'connected' || channel.ownerUserId !== principal.userId) return ignored('Mailbox Bot channel is disabled or detached.');
        let result = ignored('Email does not start work without an explicitly configured sender trigger.');
        for (const routine of services.store.list<P.Routine>('routines', item => item.ownerUserId === account.userId && item.enabled)) {
          const trigger = routine.trigger;
          if (routine.botId !== channel.botId || routine.createdAtMs > message.receivedAtMs || trigger.kind !== 'channel_event' || trigger.channelBindingId !== account.channelBindingId || trigger.event !== 'email_received' || !trigger.senders?.length || !senderMatches(message.from, trigger.senders)) continue;
          result = await runEventRoutine(services, principal, routine, { messageId: message.id, from: message.from, subject: message.subject, text: message.text, attachmentIds: message.attachmentIds, authentication: message.authentication, scan: message.scan }, `${provider.id}:${body.deliveryId}`);
        }
        return result;
      }, configuredPrincipal);
    } },
  ];
  return routes.map((route): Route => {
    if (!['POST', 'PATCH', 'DELETE'].includes(route.method) || route.mutation === false) return route;
    return { ...route, authorizeReplay: async context => {
      const principal = requireUser(context); await emailPolicy(services, principal);
      const body = parse(z.object({ botId: id.optional(), approvalId: id.optional() }).passthrough(), context.body);
      if (body.botId) ownedBot(services, principal, body.botId);
      if (body.approvalId) {
        const approval = services.store.require<P.Approval>('approvals', body.approvalId);
        if (approval.gate.targetUserId !== principal.userId || approval.gate.resolvedByUserId !== principal.userId) throw new IntegrationError('forbidden', 'Mailbox replay requires its exact authenticated approval owner.');
        ownedBot(services, principal, approval.botId);
        const reservation = services.store.get<ClaimReservation>('emailClaimReservations', principal.userId);
        if (reservation?.state === 'active') mailboxBot(services, principal, services.store.require<P.EmailAccount>('emailAccounts', reservation.accountId), approval.botId);
      }
    } };
  });
}
