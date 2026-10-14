import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../core/services';
import { IntegrationError as ApiError, boundedBytes, pinnedUrl, principal, providerRequest, scrub, sha256, userPrincipal } from '../integrations/common';

const destinations = 'exportDestinations';
const records = 'exports';
const jobs = 'exportJobs';
const packets = 'exportOutbox';
const journal = 'exportJournal';
const consents = 'contentExportConsents';
const streams: P.ExportDestination['streams'] = ['audit', 'action', 'usage', 'conversation_content'];
const residual = 'Revocation prevents future delivery and downloads, but cannot erase copies already acknowledged by an external collector. Redaction does not guarantee removal of all personal data.';
const privacyError = 'Content export is blocked by current policy, participant consent, or conversation access.';
const maxBytes = 25 * 1024 * 1024;

type DestinationState = { id: string; userId: string; watermarks: Partial<Record<P.AuditExportCreate['kind'], string>> };
type Job = { id: string; userId: string; conversationIds: string[]; requestId: string; attachmentId: string | null; invalidated: boolean };
type JournalRow = { id: string; seq: string; cursor: string; kind: P.AuditExportCreate['kind']; timestampMs: number; conversationId: string | null; payload: P.JSONObject };
type Packet = { id: string; destinationId: string; exportId: string; userId: string; seq: string; cursor: string; kind: P.AuditExportCreate['kind']; conversationIds: string[]; payload: string; state: 'queued' | 'delivering' | 'acknowledged' | 'cancelled'; attempts: number; nextAtMs: number };

function object(body: unknown, allowed: string[]): Record<string, unknown> {
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(key => !allowed.includes(key))) throw new ApiError('invalid_request', 'Unsupported export request fields.');
  return body as Record<string, unknown>;
}
function text(value: unknown, field: string, max = 120): string {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new ApiError('invalid_request', `${field} is invalid.`);
  return value;
}
function bool(value: unknown): boolean { if (typeof value !== 'boolean') throw new ApiError('invalid_request', 'Expected a boolean.'); return value; }
function kinds(value: unknown): P.ExportDestination['streams'] {
  if (!Array.isArray(value) || !value.length || value.length > streams.length || value.some(item => !streams.includes(item)) || new Set(value).size !== value.length) throw new ApiError('invalid_request', 'Choose distinct supported export streams.');
  return value as P.ExportDestination['streams'];
}
function timestamp(value: unknown): number { if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new ApiError('invalid_request', 'Export timestamps must be nonnegative safe integers.'); return value; }
function consentId(conversationId: string, userId: string): string { return JSON.stringify([conversationId, userId]); }
function currentConsent(s: BackendServices, p: Principal, conversationId: string): P.ContentExportConsent {
  const conversation = s.auth.conversation(p, conversationId);
  if (!conversation.humanUserIds.includes(p.userId)) throw new ApiError('not_found', 'Conversation not found.');
  const id = consentId(conversationId, p.userId);
  return s.store.get<P.ContentExportConsent>(consents, id) ?? s.store.put(consents, { ...s.resource('export_consent', { conversationId, userId: p.userId, enabled: false }), id });
}
function authorizeContent(s: BackendServices, p: Principal, ids: string[]): void {
  if (!s.store.metadata<P.Governance>('governance')?.contentExportEnabled || !ids.length) throw new ApiError('policy_denied', privacyError);
  for (const id of ids) {
    const conversation = s.auth.conversation(p, id);
    if (!conversation.humanUserIds.includes(p.userId) || !conversation.humanUserIds.length || conversation.humanUserIds.some(userId => !s.store.get<P.ContentExportConsent>(consents, consentId(id, userId))?.enabled)) throw new ApiError('policy_denied', privacyError);
  }
}
function enabledPrincipal(s: BackendServices, userId: string, admin = true): Principal {
  const p = userPrincipal(s, userId);
  if (admin) s.auth.requireRole(p, 'admin');
  return p;
}
function projection(row: P.AuditRecord): P.JSONObject {
  const metadata: P.JSONObject = {};
  // Allowlisted scalars, not arbitrary inputs, commands, terminal output, or prose summaries.
  for (const key of ['botId', 'runId', 'machineId', 'conversationId', 'userId', 'category', 'durationMs', 'revision', 'state', 'count', 'status', 'providerId']) {
    const value = row.metadata[key];
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean' || value === null) metadata[key] = value;
  }
  return { id: row.id, timestampMs: row.createdAtMs, actor: { kind: row.actor.kind, id: row.actor.id }, action: row.action, resourceType: row.resourceType, resourceId: row.resourceId, outcome: row.outcome, requestId: row.requestId, metadata };
}
function content(entry: P.TranscriptEntry, p: Principal): P.JSONObject | null {
  if (entry.targetedUserId && entry.targetedUserId !== p.userId) return null;
  const base: P.JSONObject = { id: entry.id, conversationId: entry.conversationId, seq: entry.seq, timestampMs: entry.timestampMs, actor: { kind: entry.actor.kind, id: entry.actor.id }, runId: entry.runId };
  if (entry.kind === 'message' && !entry.streaming) return { ...base, kind: 'message', role: entry.role, text: entry.text };
  if (entry.kind === 'card' && entry.card.type === 'text') return { ...base, kind: 'text', text: entry.card.text };
  // Raw tool invocations, gate inputs, drafts, shell output, attachments and credential cards never leave this boundary.
  return null;
}
function collector(s: BackendServices, url: string): { allowedOrigins: string[]; allowPrivate: boolean } {
  const allowedOrigins = s.config.operator.exportAllowedOrigins;
  const parsed = pinnedUrl(url, allowedOrigins);
  const privateOrigins = s.config.operator?.exportPrivateOrigins;
  if (privateOrigins !== undefined && (!Array.isArray(privateOrigins) || privateOrigins.some(origin => typeof origin !== 'string' || !allowedOrigins.includes(origin)))) throw new ApiError('capability_unavailable', 'exportPrivateOrigins must be a subset of exportAllowedOrigins.');
  return { allowedOrigins, allowPrivate: Array.isArray(privateOrigins) && privateOrigins.includes(parsed.origin) };
}

async function redactor(s: BackendServices): Promise<(value: unknown) => P.JSONValue> {
  const values = [s.config.operatorToken];
  const names = Object.keys(s.config.operator.serverSecrets);
  // A missing configured secret is a failed prerequisite, not permission to export it unredacted.
  for (const name of names) values.push(await s.secret(name));
  for (const secret of s.store.list<P.Secret>('secrets')) names.push(secret.name);
  const literals = [...new Set([...names, ...values].filter(Boolean))].sort((a, b) => b.length - a.length);
  function visit(value: unknown): P.JSONValue {
    if (typeof value === 'string') {
      let result = value.replace(/-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, '[redacted]')
        .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, '[redacted]')
        .replace(/\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]+)\b/g, '[redacted]');
      for (const literal of literals) result = result.split(literal).join('[redacted]');
      return scrub(result);
    }
    if (Array.isArray(value)) return value.map(visit);
    if (value && typeof value === 'object') {
      const result: P.JSONObject = {};
      for (const [key, item] of Object.entries(value)) {
        if (/password|secret|token|authorization|cookie|credential|private.?key|api.?key|command|argv|stdout|stderr|shell.?output|setupScript|checkScript/i.test(key)) result[key] = '[redacted]';
        else result[key] = visit(item);
      }
      return result;
    }
    return scrub(value);
  }
  return visit;
}
function wire(destination: P.ExportDestination, row: P.JSONObject, key: string, timestampMs: number): string {
  if (destination.protocol === 'ndjson_webhook') return `${JSON.stringify({ deliveryKey: key, ...row })}\n`;
  return JSON.stringify({ resourceLogs: [{ resource: { attributes: [{ key: 'service.name', value: { stringValue: 'lemon_bot' } }] }, scopeLogs: [{ scope: { name: 'lemon_bot.exports', version: '1' }, logRecords: [{ timeUnixNano: (BigInt(timestampMs) * 1000000n).toString(), severityNumber: 9, severityText: 'INFO', body: { stringValue: JSON.stringify(row) }, attributes: [{ key: 'lemon_bot.delivery_key', value: { stringValue: key } }, { key: 'lemon_bot.stream', value: { stringValue: String(row.stream) } }] }] }] }] });
}

const instances = new WeakMap<BackendServices, ReturnType<typeof buildServices>>();
export function createExportServices(s: BackendServices) {
  let existing = instances.get(s);
  if (!existing) { existing = buildServices(s); instances.set(s, existing); }
  return existing;
}
function buildServices(s: BackendServices) {
  let disposed = false;
  let active: Promise<void> | null = null;
  const controllers = new Map<string, AbortController>();

  function append(id: string, kind: JournalRow['kind'], payload: P.JSONObject, timestampMs: number, conversationId: string | null = null, cursor = s.events.cursor()): void {
    if (timestampMs < s.now() - (s.store.metadata<P.Policies>('policies')?.auditRetentionDays ?? 90) * 86400000 || s.store.get(journal, id)) return;
    s.store.transaction(() => {
      if (s.store.get(journal, id)) return;
      const seq = (BigInt(s.store.metadata<string>('exportJournalSeq') ?? '0') + 1n).toString();
      s.store.setMetadata('exportJournalSeq', seq);
      s.store.put<JournalRow>(journal, { id, seq, cursor, kind, timestampMs, conversationId, payload });
    });
  }
  function captureAction(p: Principal, input: P.JSONObject, sourceId?: string): void {
    const allowed: P.JSONObject = { actorId: p.userId };
    for (const key of ['botId', 'runId', 'machineId', 'conversationId', 'category', 'outcome', 'durationMs', 'action', 'requestId']) if (typeof input[key] === 'string' || typeof input[key] === 'number') allowed[key] = input[key];
    if (s.store.metadata<P.Policies>('policies')?.actionRecording !== true) return;
    append(`action:${sourceId ?? s.id('action')}`, 'action', allowed, s.now());
  }
  function captureUsage(p: Principal, report: P.UsageReport, atMs = s.now()): void {
    append(`usage:${p.userId}:${s.mutations.digest(report)}`, 'usage', { actorId: p.userId, report: report as unknown as P.JSONObject }, atMs);
  }
  function scan(): void {
    for (const row of s.store.list<P.AuditRecord>('auditRecords')) {
      // Delivery acknowledgments are audited locally, but never recursively exported to their own collector.
      if (row.action !== 'export.delivery') append(`audit:${row.id}`, 'audit', projection(row), row.createdAtMs);
    }
    if (s.store.metadata<P.Policies>('policies')?.actionRecording === true) {
      for (const item of s.store.list<P.ActivityItem>('activity')) {
        if (!['tool', 'approval', 'run'].includes(item.kind)) continue;
        append(`activity:${item.id}:${item.revision}`, 'action', { id: item.id, botId: item.botId, machineId: item.machineId, conversationId: item.conversationId, runId: item.runId, kind: item.kind, outcome: item.status, timestampMs: item.occurredAtMs }, item.occurredAtMs);
      }
    }
    for (const entry of s.store.list<P.TranscriptEntry>('entries')) {
      if (entry.kind !== 'message' && !(entry.kind === 'card' && entry.card.type === 'text')) continue;
      if (entry.kind === 'message' && entry.streaming) continue;
      // Journal contains references only. Content is read afresh only after current ACL/consent checks.
      append(`entry:${entry.id}:${entry.revision}`, 'conversation_content', { entryId: entry.id, revision: entry.revision }, entry.timestampMs, entry.conversationId);
    }
  }
  function watermark(): string { scan(); return s.store.metadata<string>('exportJournalSeq') ?? '0'; }
  function setRecord(record: P.ExportRecord, changes: Partial<P.ExportRecord>, userId: string): P.ExportRecord {
    const updated = s.store.put(records, s.update(record, changes));
    s.events.emit('export.upserted', updated, { userIds: [userId] });
    return updated;
  }
  function cancelContent(conversationId?: string): void {
    scan();
    for (const row of s.store.list<JournalRow>(journal, row => row.kind === 'conversation_content' && (!conversationId || row.conversationId === conversationId))) {
      s.store.put(journal, { ...row, payload: {} });
    }
    for (const packet of s.store.list<Packet>(packets, row => row.kind === 'conversation_content' && row.state !== 'acknowledged' && row.state !== 'cancelled' && (!conversationId || row.conversationIds.includes(conversationId)))) {
      controllers.get(packet.id)?.abort();
      s.store.put(packets, { ...packet, payload: '', state: 'cancelled' });
      const record = s.store.get<P.ExportRecord>(records, packet.exportId);
      if (record) setRecord(record, { state: 'failed', error: privacyError }, packet.userId);
    }
    for (const job of s.store.list<Job>(jobs, row => !row.invalidated && row.conversationIds.length > 0 && (!conversationId || row.conversationIds.includes(conversationId)))) {
      s.store.put(jobs, { ...job, invalidated: true });
      const record = s.store.get<P.ExportRecord>(records, job.id);
      if (record) setRecord(record, { state: 'failed', attachmentId: null, error: privacyError }, job.userId);
      if (job.attachmentId) {
        const attachment = s.store.get<P.Attachment>('attachments', job.attachmentId);
        if (attachment) s.store.put('attachments', s.update(attachment, { state: 'deleted' }));
      }
    }
  }
  function authorizeExportAttachment(p: Principal, attachmentId: string): void {
    const attachment = s.store.get<P.Attachment>('attachments', attachmentId);
    const job = s.store.list<Job>(jobs, row => {
      if (row.attachmentId === attachmentId) return true;
      // Attachment creation can publish metadata before its promise resolves. Recognize its
      // reserved job filename so a process crash or concurrent revoke cannot expose an orphan.
      const record = s.store.get<P.ExportRecord>(records, row.id);
      return !!record && attachment?.ownerUserId === row.userId && attachment.mime === 'application/x-ndjson' && attachment.filename === `lemon-bot-${record.kind}-${record.id}.ndjson`;
    })[0];
    if (!job) return;
    if (job.userId !== p.userId) throw new ApiError('not_found', 'Attachment not found.');
    if (job.invalidated) throw new ApiError('policy_denied', privacyError);
    const record = s.store.require<P.ExportRecord>(records, job.id);
    if (record.state !== 'completed' || record.attachmentId !== attachmentId) throw new ApiError('conflict', 'Export attachment is not complete.');
    if (job.conversationIds.length) {
      try { authorizeContent(s, p, job.conversationIds); } catch (error) { for (const id of job.conversationIds) cancelContent(id); throw error; }
    }
  }
  function ownRecord(p: Principal, record: P.ExportRecord): boolean {
    if (record.kind !== 'conversation_content') return true;
    const job = s.store.get<Job>(jobs, record.id);
    if (job) return job.userId === p.userId;
    return s.store.get<DestinationState>('exportDestinationState', record.destinationId ?? '')?.userId === p.userId;
  }
  function canReadResource(p: Principal, collection: string, entity: unknown): boolean | undefined {
    if (![destinations, records, consents].includes(collection)) return undefined;
    if (!entity || typeof entity !== 'object' || !('id' in entity) || typeof entity.id !== 'string') return false;
    try {
      const currentPrincipal = enabledPrincipal(s, p.userId, collection !== consents);
      if (collection === destinations) return s.store.get<P.ExportDestination>(destinations, entity.id) !== null;
      if (collection === consents) {
        const consent = s.store.get<P.ContentExportConsent>(consents, entity.id);
        if (!consent || consent.userId !== currentPrincipal.userId) return false;
        return s.auth.conversation(currentPrincipal, consent.conversationId).humanUserIds.includes(currentPrincipal.userId);
      }
      const record = s.store.get<P.ExportRecord>(records, entity.id);
      if (!record || !ownRecord(currentPrincipal, record)) return false;
      if (record.kind !== 'conversation_content') return true;
      const job = s.store.get<Job>(jobs, record.id);
      if (job) {
        if (job.invalidated) return false;
        authorizeContent(s, currentPrincipal, job.conversationIds);
      } else {
        const packet = s.store.list<Packet>(packets, row => row.exportId === record.id)[0];
        if (!packet || packet.userId !== currentPrincipal.userId || packet.state === 'cancelled') return false;
        authorizeContent(s, currentPrincipal, packet.conversationIds);
      }
      // A saved completed receipt must not expose a replaced/deleted attachment binding.
      if ('attachmentId' in entity && entity.attachmentId !== null && entity.attachmentId !== record.attachmentId) return false;
      return true;
    } catch { return false; }
  }
  async function enqueue(): Promise<void> {
    const enabled = s.store.list<P.ExportDestination>(destinations, row => row.enabled);
    if (!enabled.length) return;
    const redact = await redactor(s);
    for (const destination of enabled) {
      const state = s.store.require<DestinationState>('exportDestinationState', destination.id);
      let p: Principal;
      try { p = enabledPrincipal(s, state.userId); } catch { continue; }
      for (const row of s.store.list<JournalRow>(journal).sort((a, b) => BigInt(a.seq) < BigInt(b.seq) ? -1 : 1)) {
        if (!destination.streams.includes(row.kind) || BigInt(row.seq) <= BigInt(state.watermarks[row.kind] ?? '0')) continue;
        const key = `lemon_bot:${destination.id}:${row.kind}:${row.seq}`;
        s.store.transaction(() => {
          if (!s.store.get(packets, key)) {
            let payload: P.JSONObject | null = row.payload;
            if (row.kind === 'conversation_content') {
              try {
                authorizeContent(s, p, [row.conversationId!]);
                const conversation = s.auth.conversation(p, row.conversationId!);
                if (conversation.humanUserIds.some(userId => BigInt(row.seq) <= BigInt(s.store.metadata<string>(`exportConsentWatermark:${consentId(conversation.id, userId)}`) ?? '0'))) throw new ApiError('policy_denied', 'Content predates participant opt-in.');
                const entry = s.store.get<P.TranscriptEntry>('entries', String(row.payload.entryId));
                payload = entry && entry.revision === row.payload.revision ? content(entry, p) : null;
              } catch { payload = null; }
            }
            if (payload) {
              const record = s.resource('export', { destinationId: destination.id, fromAtMs: row.timestampMs, toAtMs: row.timestampMs, kind: row.kind, state: 'queued' as const, attachmentId: null, lastDeliveredCursor: null, error: null });
              s.store.put(records, record);
              s.store.put<Packet>(packets, { id: key, destinationId: destination.id, exportId: record.id, userId: p.userId, seq: row.seq, cursor: row.cursor, kind: row.kind, conversationIds: row.conversationId ? [row.conversationId] : [], payload: wire(destination, redact({ stream: row.kind, record: payload }) as P.JSONObject, key, row.timestampMs), state: 'queued', attempts: 0, nextAtMs: 0 });
            }
          }
          state.watermarks[row.kind] = row.seq;
          s.store.put('exportDestinationState', state);
        });
      }
    }
  }
  async function deliver(packet: Packet): Promise<void> {
    const destination = s.store.get<P.ExportDestination>(destinations, packet.destinationId);
    let record = s.store.require<P.ExportRecord>(records, packet.exportId);
    if (!destination || !destination.enabled || !destination.streams.includes(packet.kind)) {
      s.store.put(packets, { ...packet, payload: '', state: 'cancelled' });
      setRecord(record, { state: 'failed', error: 'Export destination or stream was disabled before delivery.' }, packet.userId);
      return;
    }
    const controller = new AbortController();
    controllers.set(packet.id, controller);
    try {
      const p = enabledPrincipal(s, packet.userId);
      if (packet.kind === 'conversation_content') authorizeContent(s, p, packet.conversationIds);
      const options = collector(s, destination.url);
      const headers: Record<string, string> = { 'content-type': destination.protocol === 'otlp_http' ? 'application/json' : 'application/x-ndjson', 'idempotency-key': packet.id, 'x-lemon-bot-delivery-key': packet.id };
      if (destination.secretRef) {
        if (!s.config.operator.serverSecrets[destination.secretRef]) throw new ApiError('capability_unavailable', 'Collector secretRef must name an operator serverSecret.');
        headers.authorization = `Bearer ${await s.secret(destination.secretRef)}`;
      }
      // Secret resolution awaits; recheck immediately before dispatch as well.
      if (packet.kind === 'conversation_content') authorizeContent(s, p, packet.conversationIds);
      if (s.store.require<Packet>(packets, packet.id).state === 'cancelled') return;
      s.store.put(packets, { ...packet, state: 'delivering', attempts: packet.attempts + 1 });
      record = setRecord(record, { state: 'running', error: null }, packet.userId);
      const response = await providerRequest(destination.url, { method: 'POST', headers, body: packet.payload, signal: controller.signal }, {
        ...options, mutation: true, maxBytes: 65536, fetch: s.http,
        beforeDispatch() {
          const current = s.store.get<P.ExportDestination>(destinations, packet.destinationId);
          if (!current?.enabled || !current.streams.includes(packet.kind) || s.store.require<Packet>(packets, packet.id).state === 'cancelled') throw new ApiError('policy_denied', 'Export was cancelled before dispatch.');
          const currentPrincipal = enabledPrincipal(s, packet.userId);
          if (packet.kind === 'conversation_content') authorizeContent(s, currentPrincipal, packet.conversationIds);
        },
      });
      const bytes = await boundedBytes(response, 65536);
      if (!response.ok) throw new ApiError('upstream_unavailable', 'Collector has not acknowledged this delivery.', true);
      if (destination.protocol === 'otlp_http' && bytes.length) {
        let result: { partialSuccess?: { rejectedLogRecords?: string | number } };
        try { result = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new ApiError('upstream_unavailable', 'Collector acknowledgment was malformed.'); }
        if (Number(result.partialSuccess?.rejectedLogRecords ?? 0) > 0) throw new ApiError('upstream_unavailable', 'Collector rejected exported log records.');
      }
      if (s.store.require<Packet>(packets, packet.id).state === 'cancelled') return;
      s.store.transaction(() => {
        s.store.put(packets, { ...packet, state: 'acknowledged', payload: '', attempts: packet.attempts + 1 });
        setRecord(record, { state: 'completed', lastDeliveredCursor: packet.cursor, error: null }, packet.userId);
      });
      s.audit(p, 'export.delivery', record.id, 'succeeded', { destinationId: destination.id, kind: packet.kind });
    } catch (error) {
      if (s.store.require<Packet>(packets, packet.id).state === 'cancelled') return;
      if (packet.kind === 'conversation_content') {
        try { authorizeContent(s, enabledPrincipal(s, packet.userId), packet.conversationIds); } catch { cancelContent(packet.conversationIds[0]); return; }
      }
      const message = error instanceof ApiError && ['capability_unavailable', 'policy_denied'].includes(error.code) ? error.message : 'Collector delivery has not been acknowledged; the same delivery key will be retried.';
      s.store.put(packets, { ...packet, state: 'queued', attempts: packet.attempts + 1, nextAtMs: s.now() + Math.min(300000, 1000 * 2 ** Math.min(packet.attempts, 8)) });
      setRecord(record, { state: 'queued', error: message }, packet.userId);
      // Do not audit every retry: an unavailable collector must not feed an infinite self-export loop.
    } finally { controllers.delete(packet.id); }
  }
  async function historical(record: P.ExportRecord, job: Job): Promise<void> {
    let p: Principal | null = null;
    try {
      p = enabledPrincipal(s, job.userId);
      if (job.invalidated) throw new ApiError('policy_denied', privacyError);
      if (record.kind === 'conversation_content') authorizeContent(s, p, job.conversationIds);
      record = setRecord(record, { state: 'running', error: null }, job.userId);
      const rows: P.JSONObject[] = [];
      const inRange = (time: number) => time >= record.fromAtMs && time < record.toAtMs;
      if (record.kind === 'audit') for (const audit of s.store.list<P.AuditRecord>('auditRecords', row => inRange(row.createdAtMs))) rows.push(projection(audit));
      if (record.kind === 'action') for (const row of s.store.list<JournalRow>(journal, row => row.kind === 'action' && inRange(row.timestampMs))) rows.push(row.payload);
      if (record.kind === 'usage') {
        const report = await s.invoke<P.UsageReport>(p, 'GET', `/v1/usage?fromAtMs=${record.fromAtMs}&toAtMs=${record.toAtMs}&groupBy=bot`);
        rows.push({ report: report as unknown as P.JSONObject });
      }
      if (record.kind === 'conversation_content') {
        for (const entry of s.store.list<P.TranscriptEntry>('entries', row => job.conversationIds.includes(row.conversationId) && inRange(row.timestampMs)).sort((a, b) => a.timestampMs - b.timestampMs || a.seq - b.seq || a.id.localeCompare(b.id))) {
          const row = content(entry, p); if (row) rows.push(row);
        }
      }
      const redact = await redactor(s);
      const body = [{ stream: record.kind, fromAtMs: record.fromAtMs, toAtMs: record.toAtMs, residualPrivacyRisk: residual }, ...rows].map(row => JSON.stringify(redact(row))).join('\n') + '\n';
      const bytes = new TextEncoder().encode(body);
      if (bytes.length > maxBytes) throw new ApiError('too_large', 'Choose a smaller historical export range.');
      p = enabledPrincipal(s, job.userId);
      if (record.kind === 'conversation_content') authorizeContent(s, p, job.conversationIds);
      if (s.store.require<Job>(jobs, job.id).invalidated) throw new ApiError('policy_denied', privacyError);
      let attachment = job.attachmentId ? s.store.get<P.Attachment>('attachments', job.attachmentId) : null;
      if (!attachment) {
        attachment = await s.attachments.create(p, bytes, { filename: `lemon-bot-${record.kind}-${record.id}.ndjson`, mime: 'application/x-ndjson', purpose: 'reference', clientNonce: record.id });
        job = { ...s.store.require<Job>(jobs, job.id), attachmentId: attachment.id };
        s.store.put(jobs, job);
      }
      if (record.kind === 'conversation_content') authorizeContent(s, p, job.conversationIds);
      if (s.store.require<Job>(jobs, job.id).invalidated) throw new ApiError('policy_denied', privacyError);
      // Completion requires the real immutable blob, not just attachment metadata.
      const stored = await s.attachments.bytes(attachment.id);
      if (sha256(stored) !== sha256(bytes)) throw new ApiError('internal_error', 'Export attachment bytes could not be verified.', false);
      p = enabledPrincipal(s, job.userId);
      if (s.store.require<Job>(jobs, job.id).invalidated) throw new ApiError('policy_denied', privacyError);
      if (record.kind === 'conversation_content') authorizeContent(s, p, job.conversationIds);
      setRecord(record, { state: 'completed', attachmentId: attachment.id, error: null }, job.userId);
      s.audit(p, 'export.completed', record.id, 'succeeded', { kind: record.kind, bytes: stored.length }, job.requestId);
    } catch (error) {
      if (record.kind === 'conversation_content') {
        const latest = s.store.require<Job>(jobs, job.id);
        if (latest.attachmentId) {
          const attachment = s.store.get<P.Attachment>('attachments', latest.attachmentId);
          if (attachment) s.store.put('attachments', s.update(attachment, { state: 'deleted' }));
        }
      }
      const message = error instanceof ApiError ? error.message : 'Historical export could not be completed.';
      setRecord(s.store.require<P.ExportRecord>(records, record.id), { state: 'failed', attachmentId: null, error: message }, job.userId);
      s.audit(p, 'export.completed', record.id, 'failed', { kind: record.kind }, job.requestId);
    }
  }
  async function run(): Promise<void> {
    scan();
    if (!s.store.metadata<P.Governance>('governance')?.contentExportEnabled) cancelContent();
    for (const job of s.store.list<Job>(jobs)) {
      const record = s.store.get<P.ExportRecord>(records, job.id);
      if (record && ['queued', 'running'].includes(record.state)) await historical(record, job);
    }
    for (const job of s.store.list<Job>(jobs, row => !row.invalidated && row.conversationIds.length > 0)) {
      try { authorizeContent(s, enabledPrincipal(s, job.userId), job.conversationIds); } catch { cancelContent(job.conversationIds[0]); }
    }
    await enqueue();
    for (const packet of s.store.list<Packet>(packets, row => (row.state === 'queued' || row.state === 'delivering') && row.nextAtMs <= s.now()).sort((a, b) => BigInt(a.seq) < BigInt(b.seq) ? -1 : 1)) if (!disposed) await deliver(packet);
    const days = s.store.metadata<P.Policies>('policies')?.auditRetentionDays ?? 90;
    const cutoff = s.now() - days * 86400000;
    for (const row of s.store.list<JournalRow>(journal, row => row.timestampMs < cutoff)) s.store.remove(journal, row.id);
  }
  function reconcile(): Promise<void> {
    if (disposed) return Promise.resolve();
    if (!active) active = run().finally(() => { active = null; });
    return active;
  }
  const unsubscribe = s.events.subscribe(event => {
    if (event.event === 'entry.upserted') {
      const entry = event.payload;
      if ((entry.kind === 'message' && !entry.streaming) || (entry.kind === 'card' && entry.card.type === 'text')) {
        append(`entry:${entry.id}:${entry.revision}`, 'conversation_content', { entryId: entry.id, revision: entry.revision }, entry.timestampMs, entry.conversationId, event.seq);
      }
    }
  });
  const timer = setInterval(() => { void reconcile().catch(() => { /* Persisted work remains available for the next reconciliation. */ }); }, 5000);
  timer.unref?.();
  function dispose(): void { disposed = true; clearInterval(timer); unsubscribe(); for (const controller of controllers.values()) controller.abort(); instances.delete(s); }
  return { reconcile, dispose, authorizeExportAttachment, captureAction, captureUsage, watermark, cancelContent, ownRecord, canReadResource };
}

export function createExportRoutes(s: BackendServices): Route[] {
  const service = createExportServices(s);
  const admin = (c: RequestContext) => { const p = principal(c); s.auth.requireRole(p, 'admin'); return p; };
  const mutation = (handler: (c: RequestContext, p: Principal) => unknown | Promise<unknown>, own = false) => (c: RequestContext) => s.mutations.execute(c, () => handler(c, own ? principal(c) : admin(c)));
  return [
    { method: 'GET', path: '/v1/export-destinations', auth: 'admin', handler(c) { admin(c); return s.page(c, s.store.list<P.ExportDestination>(destinations)); } },
    { method: 'POST', path: '/v1/export-destinations', auth: 'admin', mutation: true, status: 201, handler: mutation(async (c, p) => {
      const body = object(c.body, ['clientNonce', 'name', 'url', 'protocol', 'secretRef', 'streams', 'enabled']);
      const url = text(body.url, 'url', 2048); collector(s, url);
      if (!['otlp_http', 'ndjson_webhook'].includes(String(body.protocol))) throw new ApiError('invalid_request', 'Unsupported collector protocol.');
      const selected = kinds(body.streams); const enabled = bool(body.enabled);
      const secretRef = body.secretRef === undefined ? null : text(body.secretRef, 'secretRef', 256);
      if (secretRef && !s.config.operator.serverSecrets[secretRef]) throw new ApiError('capability_unavailable', 'Collector secretRef must name an operator serverSecret.');
      if (secretRef) await s.secret(secretRef);
      if (enabled && selected.includes('conversation_content') && !s.store.metadata<P.Governance>('governance')?.contentExportEnabled) throw new ApiError('policy_denied', privacyError);
      const at = service.watermark();
      const destination = s.resource('export_destination', { name: text(body.name, 'name'), url, protocol: body.protocol as P.ExportDestination['protocol'], secretRef, streams: selected, enabled });
      c.nonceResourceIds.push(destination.id);
      s.store.transaction(() => { s.store.put(destinations, destination); s.store.put<DestinationState>('exportDestinationState', { id: destination.id, userId: p.userId, watermarks: Object.fromEntries(selected.map(kind => [kind, at])) }); });
      s.audit(p, 'export.destination.created', destination.id, 'succeeded', { streams: selected, enabled }, c.requestId);
      return destination;
    }) },
    { method: 'PATCH', path: '/v1/export-destinations/:id', auth: 'admin', mutation: true, handler: mutation((c, p) => {
      const body = object(c.body, ['clientNonce', 'revision', 'enabled', 'streams']);
      const old = s.store.require<P.ExportDestination>(destinations, c.params.id!); s.mutations.checkRevision(old, body.revision);
      const selected = body.streams === undefined ? old.streams : kinds(body.streams); const enabled = body.enabled === undefined ? old.enabled : bool(body.enabled);
      const state = s.store.require<DestinationState>('exportDestinationState', old.id);
      if (selected.includes('conversation_content') && state.userId !== p.userId) throw new ApiError('forbidden', 'Only the content stream authorizer can change this destination.');
      if (enabled && selected.includes('conversation_content') && !s.store.metadata<P.Governance>('governance')?.contentExportEnabled) throw new ApiError('policy_denied', privacyError);
      const at = service.watermark();
      for (const kind of selected) if (enabled && (!old.enabled || !old.streams.includes(kind))) state.watermarks[kind] = at;
      const destination = s.update(old, { streams: selected, enabled });
      s.store.transaction(() => {
        s.store.put(destinations, destination); s.store.put('exportDestinationState', state);
        for (const packet of s.store.list<Packet>(packets, row => row.destinationId === old.id && row.state !== 'acknowledged' && (!enabled || !selected.includes(row.kind)))) {
          s.store.put(packets, { ...packet, state: 'cancelled', payload: '' });
          const record = s.store.require<P.ExportRecord>(records, packet.exportId);
          s.store.put(records, s.update(record, { state: 'failed', error: 'Export destination or stream was disabled before delivery.' }));
        }
      });
      s.audit(p, 'export.destination.updated', old.id, 'succeeded', { streams: selected, enabled }, c.requestId); return destination;
    }) },
    { method: 'DELETE', path: '/v1/export-destinations/:id', auth: 'admin', mutation: true, handler: mutation((c, p) => {
      const body = object(c.body, ['clientNonce', 'revision']); const old = s.store.require<P.ExportDestination>(destinations, c.params.id!); s.mutations.checkRevision(old, body.revision);
      s.store.remove(destinations, old.id); s.store.remove('exportDestinationState', old.id);
      for (const packet of s.store.list<Packet>(packets, row => row.destinationId === old.id && row.state !== 'acknowledged')) {
        s.store.put(packets, { ...packet, payload: '', state: 'cancelled' });
        const record = s.store.require<P.ExportRecord>(records, packet.exportId); s.store.put(records, s.update(record, { state: 'failed', error: 'Export destination was deleted before delivery.' }));
      }
      s.audit(p, 'export.destination.deleted', old.id, 'succeeded', {}, c.requestId); return { id: old.id, deleted: true };
    }) },
    { method: 'POST', path: '/v1/exports', auth: 'admin', mutation: true, status: 201, handler: mutation((c, p) => {
      const body = object(c.body, ['clientNonce', 'fromAtMs', 'toAtMs', 'kind', 'conversationIds']); const fromAtMs = timestamp(body.fromAtMs); const toAtMs = timestamp(body.toAtMs);
      if (fromAtMs > toAtMs || toAtMs > s.now() || !streams.includes(body.kind as P.AuditExportCreate['kind'])) throw new ApiError('invalid_request', 'Choose a valid historical range and stream.');
      const kind = body.kind as P.AuditExportCreate['kind']; let conversationIds: string[] = [];
      if (kind === 'conversation_content') {
        if (!Array.isArray(body.conversationIds) || !body.conversationIds.length || body.conversationIds.length > 200 || new Set(body.conversationIds).size !== body.conversationIds.length) throw new ApiError('invalid_request', 'Select distinct conversations explicitly.');
        conversationIds = body.conversationIds.map(id => text(id, 'conversationId', 256)); authorizeContent(s, p, conversationIds);
      } else if (body.conversationIds !== undefined) throw new ApiError('invalid_request', 'Conversation selection applies only to the content stream.');
      service.watermark();
      const record = s.resource('export', { destinationId: null, fromAtMs, toAtMs, kind, state: 'queued' as const, attachmentId: null, lastDeliveredCursor: null, error: null });
      c.nonceResourceIds.push(record.id);
      s.store.transaction(() => { s.store.put(records, record); s.store.put<Job>(jobs, { id: record.id, userId: p.userId, conversationIds, requestId: c.requestId, attachmentId: null, invalidated: false }); });
      s.audit(p, 'export.created', record.id, 'succeeded', { kind, fromAtMs, toAtMs, conversationCount: conversationIds.length, residualPrivacyRisk: residual }, c.requestId);
      s.events.emit('export.upserted', record, { userIds: [p.userId] }); return record;
    }) },
    { method: 'GET', path: '/v1/exports', auth: 'admin', handler(c) { const p = admin(c); return s.page(c, s.store.list<P.ExportRecord>(records, row => service.ownRecord(p, row))); } },
    { method: 'GET', path: '/v1/exports/:id', auth: 'admin', handler(c) { const p = admin(c); const record = s.store.require<P.ExportRecord>(records, c.params.id!); if (!service.ownRecord(p, record)) throw new ApiError('not_found', 'Export not found.'); return record; } },
    { method: 'GET', path: '/v1/conversations/:id/export-consent', auth: 'member', handler(c) { return currentConsent(s, principal(c), c.params.id!); } },
    { method: 'PUT', path: '/v1/conversations/:id/export-consent', auth: 'member', mutation: true, handler: mutation((c, p) => {
      const body = object(c.body, ['clientNonce', 'revision', 'enabled']); const old = currentConsent(s, p, c.params.id!); s.mutations.checkRevision(old, body.revision);
      const enabled = bool(body.enabled); const result = s.store.put(consents, s.update(old, { enabled }));
      if (enabled && !old.enabled) s.store.setMetadata(`exportConsentWatermark:${consentId(old.conversationId, p.userId)}`, service.watermark());
      if (!enabled) service.cancelContent(old.conversationId);
      s.audit(p, 'export.consent.updated', old.conversationId, 'succeeded', { enabled, residualPrivacyRisk: residual }, c.requestId); return result;
    }, true) },
  ];
}
