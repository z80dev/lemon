import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { ApiError } from '../../src/core/errors';
import { createConversationRoutes, sendMessage } from '../../src/core/conversations';
import { createRuntimeService } from '../../src/runtime/runs';
import { fixture, type TestRuntimeFixture } from './fixture';

const nonce = 'message_receipt_nonce_123456';
async function lookup(f: TestRuntimeFixture, clientNonce = nonce, actor = f.alice, conversationId = f.conversation.id): Promise<P.MessageReceipt> {
  const route = createConversationRoutes(f.services).find(route => route.method === 'GET' && route.path === '/v1/conversations/:id/messages/receipts/:nonce');
  expect(route).toBeDefined();
  return Promise.resolve(route!.handler(f.context(route!, undefined, actor, { id: conversationId, nonce: clientNonce }))) as Promise<P.MessageReceipt>;
}

describe('read-only message submission receipts', () => {
  test('lost HTTP acknowledgements resolve using the original receipt with current runs and no dispatch', async () => {
    const f = fixture(), runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      const sent = await sendMessage(f.services, f.alice, f.conversation.id, { clientNonce: nonce, text: 'Original remote message' });
      const run = f.services.update(sent.runs[0]!, { status: 'succeeded' as const, completedAtMs: f.services.now() }); f.store.put('runs', run);
      const before = f.calls.length;
      const receipt = await lookup(f);
      expect(receipt.clientNonce).toBe(nonce); expect(receipt.status).toBe('accepted'); expect(receipt.entries).toEqual(sent.entries);
      expect(receipt.runs).toEqual([run]); expect(receipt.delivery).toEqual(sent.delivery); expect(f.calls).toHaveLength(before);
      expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(1);
    } finally { runtime.close(); f.store.close(); }
  });
  test('a partial group receipt cannot release the other target while its run is not yet reserved', async () => {
    const f = fixture(), runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const second = { ...f.bot, id: 'second_owned_bot', profileId: 'lb-second' }; f.store.put('bots', second);
    f.store.setMetadata(`botMcp:${second.id}`, f.store.metadata(`botMcp:${f.bot.id}`));
    const room: P.Conversation = { ...f.conversation, kind: 'group', botIds: [f.bot.id, second.id] }; f.store.put('conversations', room);
    const waiting = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
    const submit = runtime.submit.bind(runtime);
    runtime.submit = async (actor, conversation, bot, message, context) => { if (bot.id === second.id) { waiting.resolve(); await release.promise; } return submit(actor, conversation, bot, message, context); };
    const sending = sendMessage(f.services, f.alice, room.id, { clientNonce: nonce, text: 'Both targets', everyone: true });
    try {
      await waiting.promise;
      const partial = await lookup(f);
      expect(partial.status).toBe('outcome_unknown'); expect(partial.runs).toHaveLength(1); expect(partial.delivery).toHaveLength(1);
      release.resolve(); await sending;
      const complete = await lookup(f);
      expect(complete.status).toBe('accepted'); expect(complete.runs).toHaveLength(2); expect(complete.delivery).toHaveLength(2);
    } finally { release.resolve(); await sending; runtime.close(); f.store.close(); }
  });
  test('recorded refusals remain actual failed runs instead of an invented successful send', async () => {
    const f = fixture(), runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    runtime.submit = async () => { throw new ApiError('capability_unavailable', 'Configure the destination provider.', true); };
    try {
      await expect(sendMessage(f.services, f.alice, f.conversation.id, { clientNonce: nonce, text: 'Refused work' })).rejects.toMatchObject({ code: 'capability_unavailable' });
      const before = f.calls.length, receipt = await lookup(f);
      expect(receipt.status).toBe('accepted'); expect(receipt.delivery[0]?.effectiveMode).toBe('rejected');
      expect(receipt.runs[0]).toMatchObject({ status: 'failed', error: { code: 'capability_unavailable', message: 'Configure the destination provider.' } });
      expect(f.calls).toHaveLength(before);
    } finally { runtime.close(); f.store.close(); }
  });
  test('unknown admission stays unknown and lookup never repeats chat.send', async () => {
    const f = fixture(), runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    const original = f.rpc; f.rpc = async (method, params) => { if (method === 'chat.send') throw new ApiError('outcome_unknown', 'Controller acknowledgement lost.', false); return original(method, params); };
    try {
      await sendMessage(f.services, f.alice, f.conversation.id, { clientNonce: nonce, text: 'Uncertain work' });
      expect((await lookup(f)).status).toBe('outcome_unknown'); expect((await lookup(f)).runs[0]?.status).toBe('outcome_unknown');
      expect(f.calls.filter(call => call.method === 'chat.send')).toHaveLength(1);
    } finally { runtime.close(); f.store.close(); }
  });
  test('missing, foreign and wrong-conversation receipts are private 404s', async () => {
    const f = fixture(), runtime = createRuntimeService(f.services); f.services.runtime = runtime;
    try {
      await expect(lookup(f)).rejects.toMatchObject({ code: 'not_found' });
      await sendMessage(f.services, f.alice, f.conversation.id, { clientNonce: nonce, text: 'Private work' });
      await expect(lookup(f, nonce, f.bob)).rejects.toMatchObject({ code: 'not_found' });
      const other = { ...f.conversation, id: 'other_owned_room' }; f.store.put('conversations', other);
      await expect(lookup(f, nonce, f.alice, other.id)).rejects.toMatchObject({ code: 'not_found' });
      await expect(lookup(f, nonce, { ...f.alice, id: 'another_principal' })).rejects.toMatchObject({ code: 'not_found' });
    } finally { runtime.close(); f.store.close(); }
  });
});
