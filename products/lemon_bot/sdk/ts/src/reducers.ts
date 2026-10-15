import type { RealtimeEvent, Resource, ResourceEventPayloads, TranscriptEntry } from '../../../contracts/protocol.ts';
import { localError } from './errors.ts';

/** Keep array order stable and never let older pages/events overwrite a newer revision. */
export function upsertRevision<T extends Pick<Resource, 'id' | 'revision'>>(items: T[], incoming: T): T[] {
  const index = items.findIndex(item => item.id === incoming.id);
  if (index < 0) return [...items, incoming];
  const current = items[index]!;
  if (incoming.revision <= current.revision) return items;
  const next = [...items];
  next[index] = incoming;
  return next;
}

/** Merge REST pages through the same revision boundary as realtime. */
export function mergeRevisions<T extends Pick<Resource, 'id' | 'revision'>>(items: readonly T[], incoming: readonly T[]): T[] {
  const byId = new Map(items.map(item => [item.id, item]));
  for (const item of incoming) {
    const current = byId.get(item.id);
    if (!current || item.revision > current.revision) byId.set(item.id, item);
  }
  return [...byId.values()];
}

export type EntryDeltaResult =
  | { state: 'applied' | 'duplicate' | 'final'; entry: TranscriptEntry }
  | { state: 'reconcile'; entryId: string; reason: 'missing_entry' | 'wrong_entry' | 'offset_gap' | 'overlap_mismatch' };

/** Delta offsets are JavaScript string offsets. Final full entries are authoritative. */
export function applyEntryDelta(entry: TranscriptEntry | undefined, delta: ResourceEventPayloads['entry.delta']): EntryDeltaResult {
  if (!entry) return { state: 'reconcile', entryId: delta.entryId, reason: 'missing_entry' };
  if (entry.id !== delta.entryId || entry.conversationId !== delta.conversationId || entry.runId !== delta.runId
    || entry.kind !== 'message' || entry.role !== 'assistant') {
    return { state: 'reconcile', entryId: delta.entryId, reason: 'wrong_entry' };
  }
  if (!entry.streaming) return { state: 'final', entry };
  if (!Number.isSafeInteger(delta.offset) || delta.offset < 0 || delta.offset > entry.text.length) {
    return { state: 'reconcile', entryId: delta.entryId, reason: 'offset_gap' };
  }
  if (delta.offset < entry.text.length) {
    // Never append a partial overlap. A fully contained matching replay is harmless.
    if (delta.offset + delta.text.length <= entry.text.length
      && entry.text.slice(delta.offset, delta.offset + delta.text.length) === delta.text) {
      return { state: 'duplicate', entry };
    }
    return { state: 'reconcile', entryId: delta.entryId, reason: 'overlap_mismatch' };
  }
  return { state: 'applied', entry: { ...entry, text: entry.text + delta.text } };
}

export type EntryEvent = Extract<RealtimeEvent, { event: 'entry.upserted' | 'entry.deleted' | 'entry.delta' }>;

/** Await this in onEvent: a missing offset is a GET, never a blind append or empty entry. */
export async function reduceEntryEvent(items: TranscriptEntry[], event: EntryEvent,
  loadEntry: (id: string) => Promise<TranscriptEntry>): Promise<TranscriptEntry[]> {
  if (event.event === 'entry.deleted') {
    return items.filter(item => item.id !== event.payload.id || item.conversationId !== event.payload.conversationId);
  }
  if (event.event === 'entry.upserted') {
    const next = upsertRevision(items, event.payload);
    return next === items ? items : next.sort((a, b) => a.seq - b.seq);
  }
  const index = items.findIndex(item => item.id === event.payload.entryId);
  const result = applyEntryDelta(index < 0 ? undefined : items[index], event.payload);
  if (result.state === 'reconcile') {
    const fresh = await loadEntry(result.entryId);
    if (fresh.id !== event.payload.entryId || fresh.conversationId !== event.payload.conversationId) {
      throw localError('conflict', 'Entry reconciliation returned a different entry or conversation.');
    }
    const current = index < 0 ? undefined : items[index];
    if (current && fresh.revision < current.revision) {
      throw localError('revision_conflict', 'Entry reconciliation returned an older revision.');
    }
    // GET may include the delta already; replace provisional text even at equal revision.
    const next = [...items];
    if (index < 0) next.push(fresh); else next[index] = fresh;
    return next.sort((a, b) => a.seq - b.seq);
  }
  if (result.state !== 'applied') return items;
  const next = [...items];
  next[index] = result.entry;
  return next;
}
