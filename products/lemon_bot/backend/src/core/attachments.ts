import { createHash, randomBytes } from 'node:crypto';
import { mkdir, open, lstat, readFile, readdir, unlink, link } from 'node:fs/promises';
import { join } from 'node:path';
import { fileTypeFromBuffer, type FileTypeResult } from 'file-type';
import { unzipSync } from 'fflate';
import sharp from 'sharp';
import { PDFDocument } from 'pdf-lib';
import { XMLValidator } from 'fast-xml-parser';
import { inspectAudio } from '../integrations/audio';
import type * as P from '../../../contracts/protocol';
import type { AttachmentService, BackendServices, Principal, Route } from './services';
import { fail } from './errors';
import { confirm, id, mutation, parse, principal, queryObject, z } from './validation';

const MAX_FILE = 25 * 1024 * 1024;
const MAX_VIDEO = 200 * 1024 * 1024;
const STAGING_MS = 24 * 60 * 60 * 1000;
const TICKET_MS = 5 * 60 * 1000;
const upload = mutation.extend({ conversationId: id.optional(), botId: id.optional(), purpose: z.enum(['message', 'avatar', 'reference', 'audio']) });
const createInput = upload.extend({ filename: z.string().min(1).max(1024), mime: z.string().max(256).optional(), source: z.enum(['upload', 'node', 'tts', 'generated']).optional(), provenance: z.object({ botId: id.nullable(), runId: id.nullable(), machineId: id.nullable(), sourceEntryId: id.nullable(), generatedAtMs: z.number().int().nonnegative().nullable() }).strict().optional() });
const previewInput = mutation.extend({ action: z.literal('delete') });
const listQuery = z.object({ conversationId: id.optional(), botId: id.optional(), cursor: z.string().max(512).optional(), limit: z.coerce.number().int().min(1).max(200).optional() }).strict();
interface BlobRecord { id: string; basename: string; sha256: string; size: number }
interface Ticket { id: string; principal: Principal; attachmentId: string; aclDigest: string; expiresAtMs: number }
export interface AttachmentInspection { mime: string; preview: P.Attachment['preview']; width: number | null; height: number | null; durationMs: number | null }
export interface StoredAttachmentService extends AttachmentService { copy(user: Principal, sourceAttachmentId: string, metadata: P.AttachmentUpload): Promise<P.Attachment>; collect(): Promise<void>; removeDeleted(attachmentId: string): Promise<void>; serve(ticket: string, request: Request): Promise<Response>; close(): void }
const instances = new WeakMap<BackendServices, StoredAttachmentService>();
const digest = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const safeName = (name: string) => name.split(/[\\/]/).pop()!.replace(/[\u0000-\u001f\u007f]/g, '').replace(/[<>:"|?*]/g, '_').trim().slice(0, 240).replace(/[\uD800-\uDFFF]/gu, '_') || 'attachment';
const textDecoder = new TextDecoder('utf-8', { fatal: true });

function validateVideo(bytes: Uint8Array, mime: string) {
  const b = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const bad = () => fail('unsupported_media', 'Video container is damaged, truncated or unsupported.');
  if (mime === 'video/mp4' || mime === 'video/quicktime') {
    let video = false; let media = false; let movie = false;
    const walk = (start: number, end: number, depth: number): void => {
      if (depth > 8) bad();
      let p = start;
      while (p < end) {
        if (p + 8 > end) bad();
        let size = b.readUInt32BE(p); let header = 8;
        if (size === 1) { if (p + 16 > end) bad(); size = Number(b.readBigUInt64BE(p + 8)); header = 16; }
        else if (size === 0) size = end - p;
        if (!Number.isSafeInteger(size) || size < header || p + size > end) bad();
        const kind = b.toString('ascii', p + 4, p + 8);
        if (kind === 'moov') movie = true;
        if (kind === 'mdat' && size > header) media = true;
        if (kind === 'hdlr' && size >= header + 12 && b.toString('ascii', p + header + 8, p + header + 12) === 'vide') video = true;
        if (['moov', 'trak', 'mdia', 'minf', 'stbl', 'moof', 'traf'].includes(kind)) walk(p + header, p + size, depth + 1);
        p += size;
      }
    };
    walk(0, b.length, 0);
    if (!movie || !media || !video) bad();
  } else if (mime === 'video/webm' || mime === 'video/x-matroska') {
    let video = false; let media = false;
    const integer = (p: number, keepMarker: boolean) => {
      const first = b[p];
      if (!first) return bad();
      let width = 1; let marker = 128;
      while (!(first & marker)) { marker >>= 1; width++; }
      if (width > 8 || p + width > b.length) return bad();
      let value = keepMarker ? first : first & (marker - 1);
      for (let i = 1; i < width; i++) value = value * 256 + b[p + i]!;
      return { width, value };
    };
    const walk = (start: number, end: number, depth: number): void => {
      if (depth > 8) bad();
      for (let p = start; p < end;) {
        const tag = integer(p, true); p += tag.width;
        const length = integer(p, false); p += length.width;
        const unknown = length.value === 2 ** (7 * length.width) - 1;
        if (unknown && ![0x18538067, 0x1f43b675].includes(tag.value)) bad();
        const finish = unknown ? end : p + length.value;
        if (!Number.isSafeInteger(finish) || finish > end || finish < p) bad();
        if ([0x1a45dfa3, 0x18538067, 0x1549a966, 0x1654ae6b, 0xae, 0xe0, 0x1f43b675, 0xa0].includes(tag.value)) walk(p, finish, depth + 1);
        if (tag.value === 0x83 && finish - p === 1 && b[p] === 1) video = true;
        if ([0xa3, 0xa1].includes(tag.value) && finish - p > 4) media = true;
        p = finish;
      }
    };
    walk(0, b.length, 0);
    if (!video || !media) bad();
  } else if (mime === 'video/vnd.avi' || mime === 'video/x-msvideo') {
    if (b.length < 24 || b.toString('ascii', 0, 4) !== 'RIFF' || b.readUInt32LE(4) + 8 !== b.length || b.toString('ascii', 8, 12) !== 'AVI ') bad();
  } else bad();
}

export async function inspectAttachment(bytes: Uint8Array, filename: string, purpose: P.AttachmentUpload['purpose']): Promise<AttachmentInspection> {
  if (!bytes.length) fail('unsupported_media', 'Empty files cannot be uploaded.');
  if (bytes.length > MAX_VIDEO) fail('too_large', 'File exceeds the video size limit.');
  let detected: FileTypeResult | undefined;
  try { detected = await fileTypeFromBuffer(bytes); } catch { fail('unsupported_media', 'File header is damaged or incomplete.'); }
  let mime = detected?.mime ?? '';
  let preview: P.Attachment['preview'] = 'download';
  let width: number | null = null;
  let height: number | null = null;
  let durationMs: number | null = null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (mime === 'image/png') {
    if (bytes.length < 45 || !Buffer.from(bytes.subarray(-12)).includes(Buffer.from('IEND'))) fail('unsupported_media', 'PNG upload is incomplete.');
    width = view.getUint32(16); height = view.getUint32(20); preview = 'image';
  } else if (mime === 'image/jpeg') {
    if (bytes.length < 4 || bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) fail('unsupported_media', 'JPEG upload is incomplete.');
    preview = 'image';
  } else if (mime === 'image/webp') {
    if (bytes.length < 20 || view.getUint32(4, true) + 8 !== bytes.length) fail('unsupported_media', 'WebP upload is incomplete.');
    preview = 'image';
  } else if (mime.startsWith('image/') && ['image/gif', 'image/avif', 'image/bmp', 'image/tiff'].includes(mime)) preview = 'image';
  else if (mime === 'application/pdf') {
    const tail = Buffer.from(bytes.subarray(Math.max(0, bytes.length - 2048))).toString('latin1');
    if (!tail.includes('%%EOF')) fail('unsupported_media', 'PDF upload is incomplete.');
    if (Buffer.from(bytes).includes(Buffer.from('/Encrypt'))) fail('unsupported_media', 'Encrypted PDFs cannot be read.');
    preview = 'pdf';
  } else if (mime === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
    try {
      let total = 0;
      const entries = unzipSync(bytes, { filter(entry) {
        if (entry.originalSize > MAX_FILE || (total += entry.originalSize) > MAX_FILE) throw new Error('archive limit');
        return entry.name === 'word/document.xml' || entry.name === '[Content_Types].xml';
      } });
      const document = entries['word/document.xml'];
      const contentTypes = entries['[Content_Types].xml'];
      if (!document || !contentTypes) fail('unsupported_media', 'Document is damaged or unreadable.');
      const xml = textDecoder.decode(document);
      if (!xml.includes('<w:document') || XMLValidator.validate(xml) !== true || XMLValidator.validate(textDecoder.decode(contentTypes)) !== true) fail('unsupported_media', 'Document XML is damaged or unreadable.');
      preview = 'docx';
    } catch { fail('unsupported_media', 'Document is damaged, encrypted or exceeds preview bounds.'); }
  } else if (mime.startsWith('video/')) { if (purpose !== 'audio') validateVideo(bytes, mime); preview = 'video'; }
  else if (mime.startsWith('audio/') || mime === 'application/ogg') preview = 'audio';
  else if (!detected) {
    if (bytes.length > MAX_FILE) fail('too_large', 'File exceeds the non-video size limit.');
    let text: string;
    try { text = textDecoder.decode(bytes); } catch { fail('unsupported_media', 'File encoding is unsupported.'); }
    if (text.includes('\0') || /[\u0001-\u0008\u000b\u000c\u000e-\u001f]/.test(text)) fail('unsupported_media', 'Binary file type is unsupported.');
    const ext = filename.split('.').pop()?.toLowerCase();
    mime = 'text/plain'; preview = 'text';
    if (ext === 'json') { try { JSON.parse(text); } catch { fail('unsupported_media', 'JSON document is damaged.'); } mime = 'application/json'; preview = 'json'; }
    else if (ext === 'md' || ext === 'markdown') { mime = 'text/markdown'; preview = 'markdown'; }
    else if (ext === 'csv' || ext === 'tsv') { mime = ext === 'csv' ? 'text/csv' : 'text/tab-separated-values'; preview = 'table'; }
    else if (/^\s*(?:<!doctype html|<html(?:\s|>))/i.test(text)) { mime = 'text/html'; preview = 'html'; }
  } else if (!['application/zip', 'application/gzip', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'application/vnd.ms-excel', 'application/msword', 'application/vnd.ms-powerpoint'].includes(mime)) fail('unsupported_media', 'File type is unsupported.');
  if (preview !== 'video' && bytes.length > MAX_FILE) fail('too_large', 'File exceeds the non-video size limit.');
  if (purpose === 'avatar' && (!['image/png', 'image/jpeg', 'image/webp'].includes(mime) || bytes.length >= MAX_FILE)) fail('unsupported_media', 'Avatar must be PNG, JPEG or WebP below 25 MiB.');
  if (width === 0 || height === 0 || (width !== null && height !== null && width * height > 100_000_000)) fail('unsupported_media', 'Image dimensions exceed decoding bounds.');
  if (preview === 'audio' || purpose === 'audio') {
    const audio = inspectAudio(bytes);
    mime = audio.mime; durationMs = audio.durationMs; preview = 'audio';
  }
  if (preview === 'image') {
    try {
      const image = sharp(bytes, { limitInputPixels: 100_000_000, failOn: 'warning' });
      const metadata = await image.metadata();
      await image.stats();
      width = metadata.width ?? null; height = metadata.height ?? null;
    } catch { fail('unsupported_media', 'Image is damaged or cannot be decoded safely.'); }
  }
  if (preview === 'pdf') {
    try {
      const pdf = await PDFDocument.load(bytes, { ignoreEncryption: false, throwOnInvalidObject: true });
      if (pdf.getPageCount() < 1) fail('unsupported_media', 'PDF has no readable pages.');
    } catch { fail('unsupported_media', 'PDF is damaged, encrypted or unreadable.'); }
  }
  return { mime, preview, width, height, durationMs };
}

function ownedBot(services: BackendServices, user: Principal, botId: string) {
  const bot = services.auth.bot(user, botId);
  if (bot.ownerUserId !== user.userId) fail('forbidden', 'Only your own Bot may be used for attachments.');
  return bot;
}

function ownedConversation(services: BackendServices, user: Principal, conversationId: string) {
  const conversation = services.auth.conversation(user, conversationId);
  if (conversation.ownerUserId !== user.userId) fail('forbidden', 'Attachments require your own conversation.');
  for (const botId of conversation.botIds) ownedBot(services, user, botId);
  return conversation;
}

export function createAttachmentService(services: BackendServices): StoredAttachmentService {
  const existing = instances.get(services);
  if (existing) return existing;
  const root = join(services.config.dataDir, 'attachments');
  const blobs = join(root, 'blobs');
  const staging = join(root, 'staging');
  const ready = (async () => {
    for (const path of [services.config.dataDir, root, blobs, staging]) {
      await mkdir(path, { recursive: true, mode: 0o700 });
      const stat = await lstat(path);
      if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) fail('internal_error', 'Attachment directory must be private.');
    }
  })();
  // Observe initialization failures immediately; operations still propagate the same failure.
  void ready.catch(() => {});
  const pathFor = (record: BlobRecord) => {
    if (!/^[a-f0-9]{64}-[a-f0-9]{32}$/.test(record.basename)) fail('internal_error', 'Attachment storage metadata is invalid.');
    return join(blobs, record.basename);
  };
  const visible = (user: Principal, attachmentId: string) => {
    if (user.sessionId) {
      const session = services.store.get<P.AuthSession>('authSessions', user.sessionId);
      const secret = services.store.get<{ revoked: boolean }>('sessionSecrets', user.sessionId);
      if (!session || !secret || secret.revoked || session.userId !== user.userId || (session.expiresAtMs !== null && session.expiresAtMs <= services.now())) fail('forbidden', 'Download session has been revoked.');
    }
    const member = services.auth.member(user.userId);
    const workspace = services.store.get<P.Workspace>('workspaces', user.workspaceId);
    if (!member.enabled || (workspace && !workspace.enabled)) fail('forbidden', 'Download access has been revoked.');
    services.integrations.authorizeExportAttachment?.(user, attachmentId);
    const attachment = services.auth.attachment(user, attachmentId);
    if (attachment.ownerUserId !== user.userId) fail('forbidden', 'Attachment belongs to another owner.');
    if (attachment.botId) ownedBot(services, user, attachment.botId);
    if (attachment.conversationId) ownedConversation(services, user, attachment.conversationId);
    if (attachment.state !== 'ready') fail('not_found', 'Attachment has been deleted.');
    return attachment;
  };
  const aclDigest = (user: Principal, attachment: P.Attachment) => {
    const member = services.auth.member(user.userId);
    const workspace = services.store.get<P.Workspace>('workspaces', user.workspaceId);
    const conversation = attachment.conversationId ? services.store.get<P.Conversation>('conversations', attachment.conversationId) : null;
    const botIds = [...new Set([...(conversation?.botIds ?? []), ...(attachment.botId ? [attachment.botId] : [])])].sort();
    return services.mutations.digest({
      principal: { kind: user.kind, id: user.id, userId: user.userId, workspaceId: user.workspaceId },
      attachment: { id: attachment.id, revision: attachment.revision, state: attachment.state, ownerUserId: attachment.ownerUserId, conversationId: attachment.conversationId, botId: attachment.botId },
      member: { id: member.id, userId: member.userId, enabled: member.enabled, role: member.role },
      workspace: workspace ? { id: workspace.id, enabled: workspace.enabled } : null,
      conversation: conversation ? { id: conversation.id, kind: conversation.kind, ownerUserId: conversation.ownerUserId, botIds: [...conversation.botIds].sort() } : null,
      bots: botIds.map(botId => {
        const bot = services.store.get<P.Bot>('bots', botId);
        return bot ? { id: bot.id, ownerUserId: bot.ownerUserId, avatarAttached: bot.avatar.attachmentId === attachment.id, referenceAttached: bot.referenceAttachmentIds.includes(attachment.id) } : { id: botId, missing: true };
      }),
      aclRevision: services.store.metadata('aclRevision'),
    });
  };
  const referenced = (attachmentId: string) => {
    if (services.store.list<P.Bot>('bots', b => b.avatar.attachmentId === attachmentId || b.referenceAttachmentIds.includes(attachmentId)).length) return true;
    if (services.store.list<P.ComposerDraft>('composerDrafts', d => d.attachmentIds.includes(attachmentId)).length) return true;
    if (services.store.list<P.Draft>('drafts', d => d.content.attachmentIds.includes(attachmentId)).length) return true;
    if (services.store.list<P.BotTemplate>('templates', t => t.content.avatar.attachmentId === attachmentId).length) return true;
    return services.store.list<P.TranscriptEntry>('entries', e =>
      (e.kind === 'message' && e.attachmentIds.includes(attachmentId)) ||
      (e.kind === 'user_attachment' && e.attachmentId === attachmentId) ||
      (e.kind === 'mcp_app' && e.snapshotAttachmentId === attachmentId) ||
      (e.kind === 'card' && ((e.card.type === 'attachment' && e.card.attachmentId === attachmentId) || (e.card.type === 'voice_memo' && e.card.attachmentId === attachmentId)))
    ).length > 0;
  };
  const publishBlob = async (bytes: Uint8Array, sha256: string) => {
    const basename = `${sha256}-${randomBytes(16).toString('hex')}`;
    const temporaryPath = join(staging, basename);
    const file = await open(temporaryPath, 'wx', 0o600);
    try { await file.writeFile(bytes); await file.sync(); await file.chmod(0o400); } finally { await file.close(); }
    // Exclusive publication gives each resource its own immutable path and deletion scope.
    await link(temporaryPath, join(blobs, basename));
    await unlink(temporaryPath);
    for (const directory of [blobs, staging]) {
      const handle = await open(directory, 'r');
      try { await handle.sync(); } finally { await handle.close(); }
    }
    return basename;
  };
  const service: StoredAttachmentService = {
    async create(user, inputBytes, metadata) {
      const input = parse(createInput, metadata);
      const filename = safeName(input.filename);
      if (input.conversationId) ownedConversation(services, user, input.conversationId);
      const bot = input.botId ? ownedBot(services, user, input.botId) : null;
      if (input.conversationId && bot && !ownedConversation(services, user, input.conversationId).botIds.includes(bot.id)) fail('invalid_request', 'Bot is not part of the attachment conversation.');
      const provenance: P.DeliverableProvenance = input.provenance ?? { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: null };
      if (provenance.botId) {
        const sourceBot = ownedBot(services, user, provenance.botId);
        if (provenance.machineId !== null && provenance.machineId !== sourceBot.machineId) fail('invalid_request', 'Artifact machine provenance does not match its Bot.');
        if (provenance.runId) {
          if (provenance.machineId !== sourceBot.machineId) fail('invalid_request', 'Run artifact requires the actual execution machine.');
          const run = services.store.require<P.Run>('runs', provenance.runId);
          if (run.initiatorUserId !== user.userId) fail('forbidden', 'Artifact run belongs to another actor.');
          ownedConversation(services, user, run.conversationId);
          if (run.botId !== sourceBot.id || (input.conversationId && run.conversationId !== input.conversationId)) fail('invalid_request', 'Artifact run provenance does not match its scope.');
        }
      } else if (provenance.runId || (provenance.generatedAtMs !== null && input.source !== 'tts' && input.source !== 'generated')) fail('invalid_request', 'Run artifact requires Bot provenance; provider-only generation requires its trusted source.');
      else if (provenance.machineId) services.auth.machine(user, provenance.machineId);
      if (provenance.sourceEntryId) {
        const entry = services.store.require<P.TranscriptEntry>('entries', provenance.sourceEntryId);
        ownedConversation(services, user, entry.conversationId);
        if (input.conversationId && entry.conversationId !== input.conversationId) fail('invalid_request', 'Artifact source entry belongs to another conversation.');
      }
      // Keep an owned snapshot across asynchronous sniffing and writes.
      const bytes = Uint8Array.from(inputBytes);
      const description = await inspectAttachment(bytes, filename, input.purpose);
      if (input.source === 'tts' && description.preview !== 'audio') fail('invalid_request', 'Synthesized speech must contain actual audio.');
      if (input.source === 'node' && provenance.machineId === null) fail('invalid_request', 'Node attachment requires its actual machine provenance.');
      await ready;
      if (input.conversationId) ownedConversation(services, user, input.conversationId);
      if (input.botId) ownedBot(services, user, input.botId);
      const sha256 = digest(bytes);
      const basename = await publishBlob(bytes, sha256);
      const attachment: P.Attachment = services.resource('attachment', { ownerUserId: user.userId, conversationId: input.conversationId ?? null, botId: input.botId ?? null, filename, size: bytes.length, sha256, ...description, source: input.source ?? (provenance.runId ? 'generated' as const : provenance.machineId ? 'node' as const : 'upload' as const), state: 'ready' as const, provenance });
      services.store.transaction(() => {
        if (input.conversationId) ownedConversation(services, user, input.conversationId);
        if (input.botId) ownedBot(services, user, input.botId);
        if (provenance.botId) ownedBot(services, user, provenance.botId);
        else if (provenance.machineId) services.auth.machine(user, provenance.machineId);
        services.store.put('attachmentBlobs', { id: attachment.id, basename, sha256, size: bytes.length } satisfies BlobRecord);
        services.store.put('attachments', attachment);
        services.store.setMetadata(`attachmentPurpose:${attachment.id}`, input.purpose);
        services.events.emit('attachment.upserted', attachment, { userIds: [attachment.ownerUserId], ...(attachment.conversationId ? { conversationId: attachment.conversationId } : {}) });
      });
      return attachment;
    },
    async copy(user, sourceAttachmentId, metadata) {
      const input = parse(upload, metadata);
      const source = visible(user, sourceAttachmentId);
      const authorizeTarget = () => {
        const conversation = input.conversationId ? ownedConversation(services, user, input.conversationId) : null;
        const bot = input.botId ? ownedBot(services, user, input.botId) : null;
        if (conversation && bot && !conversation.botIds.includes(bot.id)) fail('invalid_request', 'Bot is not part of the copied attachment conversation.');
      };
      authorizeTarget();
      const bytes = await service.bytes(source.id);
      const description = await inspectAttachment(bytes, source.filename, input.purpose);
      const current = visible(user, source.id);
      services.mutations.checkRevision(current, source.revision);
      authorizeTarget();
      const basename = await publishBlob(bytes, source.sha256);
      services.mutations.checkRevision(visible(user, source.id), source.revision);
      authorizeTarget();
      // Historical provenance belongs to the verified immutable original, not current placement or retained Run rows.
      const attachment: P.Attachment = services.resource('attachment', { ownerUserId: user.userId, conversationId: input.conversationId ?? null, botId: input.botId ?? null, filename: source.filename, size: source.size, sha256: source.sha256, ...description, source: source.source, state: 'ready' as const, provenance: source.provenance });
      services.store.transaction(() => {
        services.store.put('attachmentBlobs', { id: attachment.id, basename, sha256: attachment.sha256, size: attachment.size } satisfies BlobRecord);
        services.store.put('attachments', attachment);
        services.store.setMetadata(`attachmentPurpose:${attachment.id}`, input.purpose);
        services.events.emit('attachment.upserted', attachment, { userIds: [attachment.ownerUserId], ...(attachment.conversationId ? { conversationId: attachment.conversationId } : {}) });
      });
      return attachment;
    },
    async bytes(attachmentId) {
      await ready;
      const attachment = services.store.require<P.Attachment>('attachments', attachmentId);
      if (attachment.state !== 'ready') fail('not_found', 'Attachment has been deleted.');
      const record = services.store.require<BlobRecord>('attachmentBlobs', attachmentId);
      const path = pathFor(record);
      const stat = await lstat(path).catch(() => fail('not_found', 'Attachment bytes are unavailable.'));
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== attachment.size) fail('internal_error', 'Attachment storage integrity check failed.');
      const bytes = await readFile(path);
      if (digest(bytes) !== attachment.sha256 || record.sha256 !== attachment.sha256) fail('internal_error', 'Attachment checksum does not match.');
      return bytes;
    },
    download(user, attachmentId) {
      const attachment = visible(user, attachmentId);
      const ticket: Ticket = { id: randomBytes(32).toString('base64url'), principal: user, attachmentId, aclDigest: aclDigest(user, attachment), expiresAtMs: services.now() + TICKET_MS };
      services.store.put('attachmentTickets', ticket);
      return { url: `${services.config.publicUrl.replace(/\/$/, '')}/v1/downloads/${ticket.id}`, expiresAtMs: ticket.expiresAtMs, filename: attachment.filename, mime: attachment.mime, size: attachment.size };
    },
    async serve(ticketId, request) {
      const ticket = services.store.get<Ticket>('attachmentTickets', ticketId);
      if (!ticket) fail('not_found', 'Download ticket does not exist.');
      if (ticket.expiresAtMs <= services.now()) fail('expired', 'Download ticket has expired.');
      const attachment = visible(ticket.principal, ticket.attachmentId);
      if (aclDigest(ticket.principal, attachment) !== ticket.aclDigest) fail('forbidden', 'Download permission has changed; request a new link.');
      const bytes = await service.bytes(attachment.id);
      // Authorization may change while the file is being read.
      if (aclDigest(ticket.principal, visible(ticket.principal, attachment.id)) !== ticket.aclDigest) fail('forbidden', 'Download permission has changed.');
      if (ticket.expiresAtMs <= services.now()) fail('expired', 'Download ticket has expired.');
      const headers = new Headers({ 'Content-Type': attachment.mime, 'Content-Disposition': `attachment; filename="${attachment.filename.replace(/[^\x20-\x7e]|["\\]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(attachment.filename).replace(/['()*]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)}`, 'Content-Length': String(bytes.length), 'ETag': `"${attachment.sha256}"`, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "sandbox; default-src 'none'" });
      const range = request.headers.get('Range');
      if (!range || (request.headers.has('If-Range') && request.headers.get('If-Range') !== headers.get('ETag'))) return new Response(bytes, { status: 200, headers });
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      let start = 0; let end = bytes.length - 1;
      if (match && (match[1] || match[2])) {
        if (!match[1]) { const suffix = Number(match[2]); start = Math.max(0, bytes.length - suffix); if (!suffix || !Number.isSafeInteger(suffix)) start = bytes.length; }
        else { start = Number(match[1]); if (match[2]) end = Math.min(end, Number(match[2])); }
      } else start = bytes.length;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= bytes.length || end < start) {
        headers.set('Content-Range', `bytes */${bytes.length}`); headers.set('Content-Length', '0');
        return new Response(null, { status: 416, headers });
      }
      headers.set('Content-Range', `bytes ${start}-${end}/${bytes.length}`); headers.set('Content-Length', String(end - start + 1));
      return new Response(bytes.subarray(start, end + 1), { status: 206, headers });
    },
    async collect() {
      await ready;
      for (const ticket of services.store.list<Ticket>('attachmentTickets', t => t.expiresAtMs <= services.now())) services.store.remove('attachmentTickets', ticket.id);
      for (const attachment of services.store.list<P.Attachment>('attachments', a => a.state === 'deleted' || (a.conversationId === null && a.botId === null && a.createdAtMs + STAGING_MS <= services.now()))) {
        if (attachment.state === 'ready' && referenced(attachment.id)) continue;
        const record = services.store.get<BlobRecord>('attachmentBlobs', attachment.id);
        if (attachment.state === 'ready') {
          services.store.put('attachments', services.update(attachment, { state: 'deleted' }));
          services.events.emit('attachment.deleted', { id: attachment.id, deleted: true }, { userIds: [attachment.ownerUserId] });
        }
        if (record) { await unlink(pathFor(record)).catch(error => { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }); services.store.remove('attachmentBlobs', attachment.id); }
      }
      const known = new Set(services.store.list<BlobRecord>('attachmentBlobs').map(r => r.basename));
      for (const directory of [blobs, staging]) for (const basename of await readdir(directory)) {
        if (directory === blobs && known.has(basename)) continue;
        const path = join(directory, basename);
        const stat = await lstat(path);
        if (stat.isFile() && stat.mtimeMs + STAGING_MS <= services.now()) await unlink(path);
      }
    },
    async removeDeleted(attachmentId) {
      await ready;
      const attachment = services.store.require<P.Attachment>('attachments', attachmentId);
      if (attachment.state !== 'deleted') fail('conflict', 'Attachment must be revoked before its bytes are removed.');
      const record = services.store.get<BlobRecord>('attachmentBlobs', attachmentId);
      if (!record) return;
      await unlink(pathFor(record)).catch(error => { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; });
      services.store.remove('attachmentBlobs', attachmentId);
    },
    close() { clearInterval(timer); instances.delete(services); },
  };
  const timer = setInterval(() => { void service.collect().catch(() => {}); }, 60_000);
  timer.unref();
  instances.set(services, service);
  void service.collect().catch(() => {});
  return service;
}

export function createAttachmentRoutes(services: BackendServices): Route[] {
  const service = createAttachmentService(services);
  const own = (user: Principal, attachmentId: string) => {
    const attachment = services.auth.attachment(user, attachmentId);
    if (attachment.ownerUserId !== user.userId) fail('forbidden', 'Attachment belongs to another owner.');
    if (attachment.botId) ownedBot(services, user, attachment.botId);
    if (attachment.conversationId) ownedConversation(services, user, attachment.conversationId);
    if (attachment.state !== 'ready') fail('not_found', 'Attachment has been deleted.');
    return attachment;
  };
  const effects = (attachment: P.Attachment): P.ScopeEffect[] => [
    { resourceType: 'attachment', id: attachment.id, machineId: null, operation: 'delete', explanation: 'Remove this immutable product blob and revoke all download tickets.' },
    ...(attachment.conversationId ? [{ resourceType: 'conversation', id: attachment.conversationId, machineId: null, operation: 'retain' as const, explanation: 'Transcript and attachment references remain; the original file becomes unavailable.' }] : []),
    ...(attachment.provenance.machineId ? [{ resourceType: 'machine', id: attachment.provenance.machineId, machineId: attachment.provenance.machineId, operation: 'retain' as const, explanation: 'Original host files and copies are not deleted.' }] : []),
    ...services.store.list<P.TranscriptEntry>('entries', e =>
      (e.kind === 'message' && e.attachmentIds.includes(attachment.id)) ||
      (e.kind === 'user_attachment' && e.attachmentId === attachment.id) ||
      (e.kind === 'mcp_app' && e.snapshotAttachmentId === attachment.id) ||
      (e.kind === 'card' && ((e.card.type === 'attachment' && e.card.attachmentId === attachment.id) || (e.card.type === 'voice_memo' && e.card.attachmentId === attachment.id)))
    ).map(e => ({ resourceType: 'entry', id: e.id, machineId: null, operation: 'retain' as const, explanation: 'Transcript entry remains with an unavailable attachment reference.' })),
    ...services.store.list<P.Bot>('bots', b => b.avatar.attachmentId === attachment.id || b.referenceAttachmentIds.includes(attachment.id))
      .map(b => ({ resourceType: 'bot', id: b.id, machineId: b.machineId, operation: 'retain' as const, explanation: 'Bot identity and reference IDs remain; this file becomes unavailable.' })),
    ...services.store.list<P.ComposerDraft & { id: string }>('composerDrafts', d => d.attachmentIds.includes(attachment.id))
      .map(d => ({ resourceType: 'composerDraft', id: d.id, machineId: null, operation: 'retain' as const, explanation: 'Composer draft remains with an unavailable attachment reference.' })),
    ...services.store.list<P.Draft>('drafts', d => d.content.attachmentIds.includes(attachment.id))
      .map(d => ({ resourceType: 'draft', id: d.id, machineId: null, operation: 'retain' as const, explanation: 'Outward draft remains; this attachment must be removed or replaced before sending.' })),
    ...services.store.list<P.BotTemplate>('templates', t => t.content.avatar.attachmentId === attachment.id)
      .map(t => ({ resourceType: 'template', id: t.id, machineId: null, operation: 'retain' as const, explanation: 'Template remains with an unavailable avatar reference.' })),
    { resourceType: 'backups', id: attachment.id, machineId: null, operation: 'retain', explanation: 'Operator backups and files already downloaded are outside this deletion scope.' },
  ];
  return [
    { method: 'POST', path: '/v1/attachments', auth: 'member', body: 'multipart', status: 201, handler: async context => {
      if (!(context.body instanceof FormData)) fail('invalid_request', 'Upload must be multipart/form-data.');
      const parts = [...context.body.entries()];
      if (parts.length !== 2 || context.body.getAll('metadata').length !== 1 || context.body.getAll('file').length !== 1) fail('invalid_request', 'Upload requires exactly metadata and file parts.');
      const metadataPart = context.body.get('metadata');
      const file = context.body.get('file');
      if (typeof metadataPart !== 'string' || metadataPart.length > 16384 || !(file instanceof File)) fail('invalid_request', 'Upload parts have invalid types.');
      let metadata: unknown;
      try { metadata = JSON.parse(metadataPart); } catch { fail('invalid_request', 'Upload metadata is not JSON.'); }
      const input = parse(upload, metadata);
      if (file.size > MAX_VIDEO) fail('too_large', 'File exceeds upload limits.');
      const attachment = await service.create(principal(context.user), new Uint8Array(await file.arrayBuffer()), { ...input, filename: file.name, mime: file.type });
      context.nonceResourceIds.push(attachment.id);
      return attachment;
    } },
    { method: 'GET', path: '/v1/attachments', auth: 'member', body: 'none', status: 200, handler(context) {
      const query = parse(listQuery, queryObject(context.query)); const user = principal(context.user);
      if (query.conversationId) ownedConversation(services, user, query.conversationId);
      if (query.botId) ownedBot(services, user, query.botId);
      const values = services.store.list<P.Attachment>('attachments', a => {
        if (a.ownerUserId !== user.userId || a.state !== 'ready' || (query.conversationId && a.conversationId !== query.conversationId) || (query.botId && a.botId !== query.botId)) return false;
        if (a.botId && services.store.get<P.Bot>('bots', a.botId)?.ownerUserId !== user.userId) return false;
        if (a.conversationId) {
          const conversation = services.store.get<P.Conversation>('conversations', a.conversationId);
          if (!conversation || conversation.ownerUserId !== user.userId || conversation.botIds.some(botId => services.store.get<P.Bot>('bots', botId)?.ownerUserId !== user.userId)) return false;
        }
        return services.auth.canRead(user, 'attachments', a);
      });
      return services.page(context, values, { binding: query });
    } },
    { method: 'GET', path: '/v1/attachments/:id', auth: 'member', body: 'none', status: 200, handler: context => own(principal(context.user), context.params.id!) },
    { method: 'GET', path: '/v1/attachments/:id/download', auth: 'member', body: 'none', status: 200, handler: context => service.download(principal(context.user), context.params.id!) },
    { method: 'GET', path: '/v1/downloads/:ticket', auth: 'public', body: 'none', mutation: false, status: 200, handler: context => service.serve(context.params.ticket!, context.request) },
    { method: 'POST', path: '/v1/attachments/:id/preview', auth: 'member', status: 200, handler(context) {
      parse(previewInput, context.body); const user = principal(context.user); const attachment = own(user, context.params.id!); const affected = effects(attachment);
      return services.mutations.preview(user, attachment, 'delete', attachment.filename, affected.map(e => e.explanation), affected, affected);
    } },
    { method: 'DELETE', path: '/v1/attachments/:id', auth: 'member', status: 200, handler: async context => {
      const body = parse(confirm, context.body); const user = principal(context.user); const attachment = own(user, context.params.id!);
      services.store.transaction(() => {
        services.mutations.confirm(user, attachment, 'delete', body, effects(attachment));
        services.store.put('attachments', services.update(attachment, { state: 'deleted' }));
        services.events.emit('attachment.deleted', { id: attachment.id, deleted: true }, { userIds: [attachment.ownerUserId], ...(attachment.conversationId ? { conversationId: attachment.conversationId } : {}) });
        services.audit(user, 'attachment.delete', attachment.id, 'succeeded');
      });
      await service.removeDeleted(attachment.id);
      return { id: attachment.id, deleted: true } satisfies P.Deleted;
    } },
  ];
}
