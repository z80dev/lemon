import { expect, test } from 'bun:test';
import type { Bot, Run, TranscriptEntry } from '@lemon-bot/sdk';
import { currentStep, isStreaming, staleLiveRuns } from '../src/live';

const resource = { revision: 1, createdAtMs: 1, updatedAtMs: 1 };
function run(id: string, status: Run['status'], botId = 'bot'): Run {
  return { ...resource, id, conversationId: 'conversation', botId, initiatorUserId: 'user', clientNonce: `nonce-${id}`, status, error: null, startedAtMs: 1, completedAtMs: null, routineRunId: null };
}
function message(runId: string | null, streaming = true): TranscriptEntry {
  return { ...resource, id: `entry-${runId ?? 'none'}`, conversationId: 'conversation', seq: 1, timestampMs: 1, actor: { kind: 'bot', id: 'bot', displayName: 'Bot' }, clientNonce: null, batchId: null, replyToEntryId: null, runId, targetedUserId: null, reactions: [], kind: 'message', role: 'assistant', text: 'Reply', streaming, attachmentIds: [] };
}
const conversation = { activity: [] };

test('currentStep only treats streaming entries from a live run as Writing a reply', () => {
  expect(currentStep([], [message('finished')], conversation)).toBeUndefined();

  const live = run('live', 'running');
  const finished = run('finished', 'succeeded');
  expect(currentStep([live, finished], [message(finished.id)], conversation)?.title).toBe('Thinking');
  expect(currentStep([live, finished], [message(live.id)], conversation)?.title).toBe('Writing a reply');
  expect(currentStep([run('unknown', 'outcome_unknown')], [], conversation)).toBeUndefined();
});

test('isStreaming hides the caret only when the entry run is known terminal', () => {
  const entry = message('run');
  expect(isStreaming(entry, [run('run', 'succeeded')])).toBe(false);
  expect(isStreaming(entry, [run('run', 'failed')])).toBe(false);
  expect(isStreaming(entry, [run('run', 'cancelled')])).toBe(false);
  expect(isStreaming(entry, [])).toBe(true);
  expect(isStreaming(entry, [run('run', 'running')])).toBe(true);
  expect(isStreaming(message('run', false), [run('run', 'running')])).toBe(false);
});

test('staleLiveRuns selects all this Bot nonterminal runs without changing live presentation', () => {
  const running = run('running', 'running');
  const queued = run('queued', 'queued');
  const reserved = run('reserved', 'reserved');
  const awaitingInput = run('awaiting', 'awaiting_input');
  const unknown = run('unknown', 'outcome_unknown');
  const terminal = run('terminal', 'succeeded');
  const other = run('other', 'running', 'other-bot');
  const runs = [running, queued, reserved, awaitingInput, unknown, terminal, run('failed', 'failed'), run('cancelled', 'cancelled'), other];
  const bot = { id: 'bot', activity: 'idle' as Bot['activity'] };

  expect(staleLiveRuns(bot, runs)).toEqual([running, queued, reserved, awaitingInput, unknown]);
  expect(staleLiveRuns({ ...bot, activity: 'offline' }, runs)).toEqual([running, queued, reserved, awaitingInput, unknown]);
  expect(staleLiveRuns({ ...bot, activity: 'working' }, runs)).toEqual([]);
  expect(staleLiveRuns({ ...bot, activity: 'needs_input' }, runs)).toEqual([]);
});
