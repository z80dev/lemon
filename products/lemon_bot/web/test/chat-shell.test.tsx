import { expect, test } from 'bun:test';
import type { TranscriptEntry } from '@lemon-bot/sdk';
import { version } from '../package.json';
import { appVersion, requiresClientUpdate } from '../src/version';
import { replyPreview } from '../src/features/chat/reply';

const message: TranscriptEntry = {
  id: 'entry', revision: 1, createdAtMs: 1, updatedAtMs: 1,
  conversationId: 'room', seq: 1, timestampMs: 1,
  actor: { kind: 'bot', id: 'bot', displayName: 'Maple' },
  clientNonce: null, batchId: null, replyToEntryId: null, runId: null,
  targetedUserId: null, reactions: [], kind: 'message', role: 'assistant',
  text: '**Here** is the report.\nPlease review it.', streaming: false, attachmentIds: [],
};

test('reply previews identify the author and normalize markdown to one line', () => {
  expect(replyPreview(message)).toBe('Maple: Here is the report. Please review it.');
  expect(replyPreview({ ...message, text: '😀'.repeat(41) })).toBe(`Maple: ${'😀'.repeat(40)}…`);
  expect(replyPreview({ ...message, text: '', attachmentIds: ['file'] })).toBe('Maple: File attachment');
  expect(replyPreview({ ...message, kind: 'user_attachment', attachmentId: 'file' })).toBe('Maple: File attachment');
});

test('the client version is the package version and minimum checks follow semver precedence', () => {
  expect(appVersion).toBe(version);
  for (const [current, minimum, update] of [
    ['1.0.0', '1.0.0', false], ['1.0.0', '2.0.0', true],
    ['2.0.0', '1.9.9', false], ['1.9.0', '1.10.0', true],
    ['1.1.0', '1.0.99', false], ['1.0.0', '1.0.1', true],
    ['1.0.0-beta.2', '1.0.0-beta.10', true], ['1.0.0-rc.1', '1.0.0', true],
    ['1.0.0', '1.0.0-rc.1', false], ['1.0.0+abc', '1.0.0+def', false],
  ] as const) expect(requiresClientUpdate(current, minimum)).toBe(update);
});
