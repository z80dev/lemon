import { describe, expect, test } from 'bun:test';
import { chmod, lstat, symlink, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import sharp from 'sharp';
import { PDFDocument } from 'pdf-lib';
import { zipSync, strToU8 } from 'fflate';
import type * as P from '../../../contracts/protocol';
import { createAttachmentRoutes, createAttachmentService } from '../../src/core/attachments';
import { fail } from '../../src/core/errors';
import { mediaFixture } from './attachments.fixture';
import { pcmWave } from '../../src/integrations/audio';

const nonce = 'attachment_test_nonce_01';
describe('immutable completed attachments', () => {
  test('sniffs original bytes, sanitizes filename, persists private immutable checksum-checked blobs', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services);
    try {
      const original = new TextEncoder().encode('hello world');
      const attachment = await service.create(f.user, original, { clientNonce: nonce, purpose: 'message', filename: '../../résumé\n.txt', mime: 'video/mp4' });
      expect(attachment).toMatchObject({ state: 'ready', filename: 'résumé.txt', mime: 'text/plain', preview: 'text', size: original.length, width: null, height: null, durationMs: null });
      expect(attachment.sha256).toHaveLength(64);
      const record = f.store.require<{ basename: string }>('attachmentBlobs', attachment.id);
      const path = join(f.directory, 'attachments/blobs', record.basename);
      expect((await lstat(path)).mode & 0o777).toBe(0o400);
      expect((await lstat(join(f.directory, 'attachments/blobs'))).mode & 0o777).toBe(0o700);
      expect(await service.bytes(attachment.id)).toEqual(original);
      await chmod(path, 0o600); await writeFile(path, 'HELLO WORLD');
      await expect(service.bytes(attachment.id)).rejects.toMatchObject({ code: 'internal_error' });
      await unlink(path); await symlink(join(f.directory, 'test.sqlite'), path);
      await expect(service.bytes(attachment.id)).rejects.toMatchObject({ code: 'internal_error' });
    } finally { service.close(); await f.close(); }
  });
  test('rejects incomplete, empty, invalid encoding, oversized and fake avatar/audio input', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services);
    const create = (bytes: Uint8Array, purpose: P.AttachmentUpload['purpose'] = 'message') => service.create(f.user, bytes, { clientNonce: nonce, purpose, filename: 'test.png' });
    try {
      await expect(create(new Uint8Array())).rejects.toMatchObject({ code: 'unsupported_media' });
      await expect(create(new Uint8Array([0xff, 0, 1]))).rejects.toMatchObject({ code: 'unsupported_media' });
      await expect(create(new TextEncoder().encode('not a picture'), 'avatar')).rejects.toMatchObject({ code: 'unsupported_media' });
      await expect(create(new TextEncoder().encode('not audio'), 'audio')).rejects.toMatchObject({ code: 'unsupported_media' });
      await expect(create(new Uint8Array(25 * 1024 * 1024 + 1).fill(65))).rejects.toMatchObject({ code: 'too_large' });
      await expect(create(Buffer.from('89504e470d0a1a0a', 'hex'))).rejects.toMatchObject({ code: 'unsupported_media' });
      expect(f.store.list('attachments')).toHaveLength(0);
    } finally { service.close(); await f.close(); }
  });
  test('advertises previews only for genuine supported originals; slides and archives stay downloadable', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services);
    try {
      const png = await sharp({ create: { width: 2, height: 3, channels: 3, background: 'red' } }).png().toBuffer();
      const image = await service.create(f.user, png, { clientNonce: nonce, purpose: 'avatar', filename: 'image.dat' });
      expect(image).toMatchObject({ preview: 'image', mime: 'image/png', width: 2, height: 3 });
      const pdf = await PDFDocument.create(); pdf.addPage();
      expect((await service.create(f.user, await pdf.save(), { clientNonce: nonce, purpose: 'message', filename: 'report.pdf' })).preview).toBe('pdf');
      await expect(service.create(f.user, Buffer.from('%PDF-1.7\ntruncated'), { clientNonce: nonce, purpose: 'message', filename: 'report.pdf' })).rejects.toMatchObject({ code: 'unsupported_media' });
      const docx = zipSync({ '[Content_Types].xml': strToU8('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'), 'word/document.xml': strToU8('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/></w:body></w:document>') });
      expect((await service.create(f.user, docx, { clientNonce: nonce, purpose: 'message', filename: 'report.docx' })).preview).toBe('docx');
      for (const [filename, text, preview] of [['a.csv', 'a,b\n1,2', 'table'], ['a.md', '# Heading', 'markdown'], ['a.json', '{"a":1}', 'json'], ['a.html', '<!doctype html><html><script>alert(1)</script></html>', 'html']]) {
        expect((await service.create(f.user, strToU8(text!), { clientNonce: nonce, purpose: 'message', filename: filename! })).preview).toBe(preview!);
      }
      const archive = await service.create(f.user, zipSync({ 'a.txt': strToU8('data') }), { clientNonce: nonce, purpose: 'message', filename: 'archive.zip' });
      expect(archive.preview).toBe('download');
    } finally { service.close(); await f.close(); }
  });
  test('multipart is exact and same-nonce replay is bound to full original bytes', async () => {
    const f = await mediaFixture(); const routes = createAttachmentRoutes(f.services); const service = createAttachmentService(f.services);
    const route = routes.find(r => r.method === 'POST' && r.path === '/v1/attachments')!;
    const form = (text: string) => { const body = new FormData(); body.set('metadata', JSON.stringify({ clientNonce: nonce, purpose: 'message' })); body.set('file', new File([text], 'file.txt')); return body; };
    try {
      const body = form('original'); const context = f.context(route, body);
      const first = await f.services.mutations.execute(context, () => route.handler(context)) as P.Attachment;
      const retry = f.context(route, form('original'));
      expect(await f.services.mutations.execute(retry, () => route.handler(retry))).toEqual(first);
      const changed = f.context(route, form('changed'));
      await expect(f.services.mutations.execute(changed, () => route.handler(changed))).rejects.toMatchObject({ code: 'nonce_conflict' });
      expect(f.store.list('attachments')).toHaveLength(1);
      const extra = form('extra'); extra.append('unknown', 'value');
      await expect(Promise.resolve(route.handler(f.context(route, extra)))).rejects.toMatchObject({ code: 'invalid_request' });
      const duplicate = form('extra'); duplicate.append('file', new File(['extra'], 'extra.txt'));
      await expect(Promise.resolve(route.handler(f.context(route, duplicate)))).rejects.toMatchObject({ code: 'invalid_request' });
      const unsupported = form('extra'); unsupported.set('metadata', JSON.stringify({ clientNonce: nonce, purpose: 'message', sourceUrl: 'https://evil.example' }));
      await expect(Promise.resolve(route.handler(f.context(route, unsupported)))).rejects.toMatchObject({ code: 'invalid_request' });
      const forgedSource = form('extra'); forgedSource.set('metadata', JSON.stringify({ clientNonce: nonce, purpose: 'message', source: 'tts' }));
      await expect(Promise.resolve(route.handler(f.context(route, forgedSource)))).rejects.toMatchObject({ code: 'invalid_request' });
    } finally { service.close(); await f.close(); }
  });
  test('signed downloads need no bearer, handle single ranges, and invalidate on session and ACL revision', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services);
    try {
      const attachment = await service.create(f.user, strToU8('0123456789'), { clientNonce: nonce, purpose: 'message', filename: 'numbers.txt', conversationId: f.conversation.id });
      const download = service.download(f.user, attachment.id); const ticket = download.url.split('/').pop()!;
      const response = await service.serve(ticket, new Request(download.url));
      expect(response.status).toBe(200); expect(await response.text()).toBe('0123456789');
      expect(response.headers.get('Referrer-Policy')).toBe('no-referrer'); expect(response.headers.get('Accept-Ranges')).toBe('bytes'); expect(response.headers.get('Content-Length')).toBe('10');
      for (const [range, expected, contentRange] of [['bytes=2-4', '234', 'bytes 2-4/10'], ['bytes=-3', '789', 'bytes 7-9/10'], ['bytes=8-', '89', 'bytes 8-9/10'], ['bytes=8-999', '89', 'bytes 8-9/10']]) {
        const part = await service.serve(ticket, new Request(download.url, { headers: { Range: range! } }));
        expect(part.status).toBe(206); expect(part.headers.get('Content-Range')).toBe(contentRange!); expect(await part.text()).toBe(expected!);
      }
      for (const range of ['bytes=10-', 'bytes=3-2', 'bytes=-0', 'bytes=0-1,3-4', 'bytes=-', 'bytes=9007199254740992-']) {
        const part = await service.serve(ticket, new Request(download.url, { headers: { Range: range } }));
        expect(part.status).toBe(416); expect(part.headers.get('Content-Range')).toBe('bytes */10'); expect(await part.text()).toBe('');
      }
      f.store.put('conversations', f.services.update(f.conversation, { name: 'Changed' }));
      await expect(service.serve(ticket, new Request(download.url))).rejects.toMatchObject({ code: 'forbidden' });
      const replacement = service.download(f.user, attachment.id); const replacementTicket = replacement.url.split('/').pop()!;
      f.store.put('sessionSecrets', { id: f.user.sessionId!, revoked: true });
      await expect(service.serve(replacementTicket, new Request(replacement.url))).rejects.toMatchObject({ code: 'forbidden' });
      f.store.put('sessionSecrets', { id: f.user.sessionId!, revoked: false }); f.advance(300000);
      await expect(service.serve(replacementTicket, new Request(replacement.url))).rejects.toMatchObject({ code: 'expired' });
    } finally { service.close(); await f.close(); }
  });
  test('export revocation hook runs at ticket issuance and again on actual byte fetch', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services);
    let allowed = true; let checks = 0;
    f.services.integrations.authorizeExportAttachment = () => { checks++; if (!allowed) fail('forbidden', 'Export consent was revoked.'); };
    try {
      const attachment = await service.create(f.user, strToU8('export'), { clientNonce: nonce, purpose: 'message', filename: 'export.txt' });
      const download = service.download(f.user, attachment.id);
      expect(checks).toBe(1); allowed = false;
      await expect(service.serve(download.url.split('/').pop()!, new Request(download.url))).rejects.toMatchObject({ code: 'forbidden' });
      expect(() => service.download(f.user, attachment.id)).toThrow(); expect(checks).toBe(3);
    } finally { service.close(); await f.close(); }
  });
  test('shared-room authorization never grants staging ownership or deletion; removal revokes issued ticket', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services); const routes = createAttachmentRoutes(f.services);
    try {
      const sharedBot = f.services.update(f.bot, { visibility: 'team', published: true }); f.store.put('bots', sharedBot);
      const group = f.services.update(f.conversation, { kind: 'group', humanUserIds: [f.user.userId, f.other.userId] }); f.store.put('conversations', group);
      const attachment = await service.create(f.user, strToU8('shared'), { clientNonce: nonce, purpose: 'message', filename: 'shared.txt', conversationId: group.id });
      const staged = await service.create(f.user, strToU8('own only'), { clientNonce: nonce, purpose: 'message', filename: 'staged.txt' });
      expect(() => service.download(f.other, staged.id)).toThrow();
      const download = service.download(f.other, attachment.id);
      const preview = routes.find(r => r.path.endsWith('/:id/preview'))!;
      expect(() => preview.handler(f.context(preview, { clientNonce: nonce, action: 'delete' }, f.other, { id: attachment.id }))).toThrow();
      f.store.put('conversations', f.services.update(group, { humanUserIds: [f.user.userId] }));
      await expect(service.serve(download.url.split('/').pop()!, new Request(download.url))).rejects.toThrow();
    } finally { service.close(); await f.close(); }
  });
  test('audio duration is measured from bytes and artifact provenance must reference the actual scoped run', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services);
    try {
      const wav = pcmWave(new Uint8Array(32000), 16000);
      const audio = await service.create(f.user, wav, { clientNonce: nonce, purpose: 'audio', filename: 'clip.wav', mime: 'image/png' });
      expect(audio).toMatchObject({ preview: 'audio', mime: 'audio/wav', durationMs: 1000 });
      await expect(service.create(f.user, wav.subarray(0, wav.length - 1), { clientNonce: nonce, purpose: 'audio', filename: 'clip.wav' })).rejects.toMatchObject({ code: 'unsupported_media' });
      await expect(service.create(f.user, pcmWave(new Uint8Array(16000 * 2 * 601), 16000), { clientNonce: nonce, purpose: 'audio', filename: 'long.wav' })).rejects.toMatchObject({ code: 'too_large' });
      const run: P.Run = f.services.resource('run', { conversationId: f.conversation.id, botId: f.bot.id, initiatorUserId: f.user.userId, clientNonce: nonce, status: 'succeeded', error: null, startedAtMs: f.services.now(), completedAtMs: f.services.now(), routineRunId: null }); f.store.put('runs', run);
      const provenance: P.DeliverableProvenance = { botId: f.bot.id, machineId: f.bot.machineId, runId: run.id, sourceEntryId: null, generatedAtMs: f.services.now() };
      const artifact = await service.create(f.user, strToU8('result'), { clientNonce: nonce, purpose: 'message', filename: 'result.txt', conversationId: f.conversation.id, provenance });
      expect(artifact.source).toBe('generated'); expect(artifact.provenance).toEqual(provenance);
      await expect(service.create(f.user, strToU8('result'), { clientNonce: nonce, purpose: 'message', filename: 'bad.txt', provenance: { ...provenance, machineId: 'other_machine' } })).rejects.toMatchObject({ code: 'invalid_request' });
      const download = service.download(f.user, artifact.id);
      f.store.put('attachments', f.services.update(artifact, { state: 'deleted' }));
      await expect(service.serve(download.url.split('/').pop()!, new Request(download.url))).rejects.toMatchObject({ code: 'not_found' });
    } finally { service.close(); await f.close(); }
  });
  test('deletion confirmation binds current references; expired staging GC retains composer references', async () => {
    const f = await mediaFixture(); const service = createAttachmentService(f.services); const routes = createAttachmentRoutes(f.services);
    try {
      const attachment = await service.create(f.user, strToU8('keep'), { clientNonce: nonce, purpose: 'message', filename: 'keep.txt' });
      const abandoned = await service.create(f.user, strToU8('expire'), { clientNonce: nonce, purpose: 'message', filename: 'expire.txt' });
      f.store.put('composerDrafts', { id: 'composer_1', userId: f.user.userId, conversationId: f.conversation.id, attachmentIds: [attachment.id], text: '', revision: 1, replyToEntryId: null, updatedAtMs: f.services.now() });
      f.advance(86400001); await service.collect();
      expect(f.store.require<P.Attachment>('attachments', abandoned.id).state).toBe('deleted'); expect(await service.bytes(attachment.id)).toEqual(strToU8('keep'));
      const preview = routes.find(r => r.path.endsWith('/:id/preview'))!; const remove = routes.find(r => r.method === 'DELETE')!;
      const confirmation = preview.handler(f.context(preview, { clientNonce: nonce, action: 'delete' }, f.user, { id: attachment.id })) as P.Confirmation;
      expect(confirmation.affected.some(e => e.id === 'composer_1' && e.operation === 'retain')).toBe(true);
      const entry = f.services.entry(f.user, f.conversation.id, { kind: 'user_attachment', attachmentId: attachment.id });
      const body = { clientNonce: nonce, ...confirmation };
      const exact = { clientNonce: nonce, confirmationToken: body.confirmationToken, confirmName: body.confirmName, revision: body.revision };
      await expect(Promise.resolve(remove.handler(f.context(remove, exact, f.user, { id: attachment.id })))).rejects.toMatchObject({ code: 'confirmation_required' });
      const fresh = preview.handler(f.context(preview, { clientNonce: nonce, action: 'delete' }, f.user, { id: attachment.id })) as P.Confirmation;
      expect(fresh.affected.some(e => e.id === entry.id)).toBe(true);
      const deletion = await remove.handler(f.context(remove, { clientNonce: nonce, confirmationToken: fresh.confirmationToken, confirmName: fresh.confirmName, revision: fresh.revision }, f.user, { id: attachment.id }));
      expect(deletion).toEqual({ id: attachment.id, deleted: true }); expect(f.store.require<P.TranscriptEntry>('entries', entry.id).kind).toBe('user_attachment');
      await expect(service.bytes(attachment.id)).rejects.toMatchObject({ code: 'not_found' });
    } finally { service.close(); await f.close(); }
  });
});
