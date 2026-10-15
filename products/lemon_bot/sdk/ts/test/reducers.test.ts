import { describe, expect, test } from 'bun:test';
import { applyEntryDelta, LemonBotClient, mergeRevisions, reduceEntryEvent, upsertRevision } from '../src/index.ts';
import type { ResourceEventPayloads, TranscriptEntry } from '../src/index.ts';
import { entry, fetchBoundary } from './fixtures.ts';

const delta: ResourceEventPayloads['entry.delta'] = { conversationId: entry.conversationId, entryId: entry.id, runId: 'run_1', offset: 2, text: ' there' };

describe('revision-aware transcript consumers', () => {
  test('offset append, matching replay, gaps, partial overlaps and final authority', () => {
    const appended = applyEntryDelta(entry, delta);
    expect(appended.state).toBe('applied');
    if (appended.state !== 'applied') throw new Error('Delta was not applied');
    expect(appended.entry.kind === 'message' && appended.entry.text).toBe('Hi there');
    expect(applyEntryDelta(appended.entry, delta).state).toBe('duplicate');
    expect(applyEntryDelta(entry, { ...delta, offset: 4 }).state).toBe('reconcile');
    expect(applyEntryDelta(entry, { ...delta, offset: 1, text: 'incorrect' }).state).toBe('reconcile');
    expect(applyEntryDelta(undefined, delta)).toMatchObject({ state: 'reconcile', reason: 'missing_entry' });
    expect(applyEntryDelta({ ...entry, streaming: false }, delta).state).toBe('final');
    expect(applyEntryDelta({ ...entry, text: '🤖' }, { ...delta, offset: 2, text: '!' })).toMatchObject({ state: 'applied', entry: { text: '🤖!' } });
  });

  test('missing offset reconciles through actual GET entry and propagates failure instead of empty text', async () => {
    const authoritative: TranscriptEntry = { ...entry, revision: 3, streaming: false, text: 'Full final answer' };
    const boundary = fetchBoundary(request => {
      expect(new URL(request.url).pathname).toBe('/v1/entries/entry_1');
      expect(request.method).toBe('GET');
      return Response.json(authoritative);
    });
    const client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: boundary.clientFetch });
    const updated = await reduceEntryEvent([entry], { type: 'event', seq: '10', event: 'entry.delta', payload: { ...delta, offset: 20 }, timestampMs: 1 }, id => client.call('GET /entries/:id', { params: { id } }));
    expect(updated).toEqual([authoritative]);
    expect(boundary.requests).toHaveLength(1);
    await expect(reduceEntryEvent([], { type: 'event', seq: '11', event: 'entry.delta', payload: delta, timestampMs: 1 }, async () => { throw new Error('offline read'); })).rejects.toThrow('offline read');
  });

  test('equal-revision GET replaces provisional text, terminal upsert overrides all provisional deltas', async () => {
    const fresh: TranscriptEntry = { ...entry, text: 'Hi there' };
    const reconciled = await reduceEntryEvent([entry], { type: 'event', seq: '10', event: 'entry.delta', payload: { ...delta, offset: 20 }, timestampMs: 1 }, async () => fresh);
    expect(reconciled).toEqual([fresh]);
    const final: TranscriptEntry = { ...entry, revision: 2, text: 'Authoritative correction', streaming: false };
    const terminal = await reduceEntryEvent(reconciled, { type: 'event', seq: '11', event: 'entry.upserted', payload: final, timestampMs: 1 }, async () => fresh);
    expect(terminal).toEqual([final]);
    expect(await reduceEntryEvent(terminal, { type: 'event', seq: '12', event: 'entry.delta', payload: delta, timestampMs: 1 }, async () => fresh)).toBe(terminal);
  });

  test('REST pages/realtime upserts preserve revisions, chronology and unrelated deletion', async () => {
    const newer = { ...entry, revision: 4 };
    const older = { ...entry, revision: 2 };
    const current = [newer];
    expect(upsertRevision(current, older)).toBe(current);
    expect(mergeRevisions(current, [older, { ...entry, id: 'entry_2', seq: 2 }])).toEqual([newer, { ...entry, id: 'entry_2', seq: 2 }]);
    const unsorted = [{ ...entry, id: 'entry_2', seq: 2 }, newer];
    const unchanged = await reduceEntryEvent(unsorted, { type: 'event', seq: '10', event: 'entry.upserted', payload: older, timestampMs: 1 }, async () => entry);
    expect(unchanged).toBe(unsorted);
    expect(unsorted[0]!.id).toBe('entry_2');
    const inserted = await reduceEntryEvent([{ ...newer, seq: 2 }], { type: 'event', seq: '11', event: 'entry.upserted', payload: { ...entry, id: 'entry_0', seq: 1 }, timestampMs: 1 }, async () => entry);
    expect(inserted.map(item => item.id)).toEqual(['entry_0', 'entry_1']);
    const wrongConversation = await reduceEntryEvent(current, { type: 'event', seq: '12', event: 'entry.deleted', payload: { id: entry.id, conversationId: 'other' }, timestampMs: 1 }, async () => entry);
    expect(wrongConversation).toEqual(current);
    expect(await reduceEntryEvent(current, { type: 'event', seq: '13', event: 'entry.deleted', payload: { id: entry.id, conversationId: entry.conversationId }, timestampMs: 1 }, async () => entry)).toEqual([]);
  });
});
