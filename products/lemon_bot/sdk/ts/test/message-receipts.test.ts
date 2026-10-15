import { describe, expect, test } from 'bun:test';
import { LemonBotClient } from '../src/index.ts';
import type { MessageReceipt } from '../src/index.ts';
import { fetchBoundary } from './fixtures.ts';

describe('read-only message receipt reconciliation', () => {
  test('observes the exact conversation and nonce without replaying a mutation', async () => {
    const receipt: MessageReceipt = { clientNonce: 'fixed_message_nonce_123456', entries: [], runs: [], delivery: [], status: 'outcome_unknown' };
    const boundary = fetchBoundary(request => {
      expect(request.method).toBe('GET'); expect(request.body).toBeNull();
      expect(new URL(request.url).pathname).toBe('/v1/conversations/room%20one/messages/receipts/fixed_message_nonce_123456');
      expect(request.headers.get('Authorization')).toBe('Bearer product-session');
      return Response.json(receipt);
    });
    const client = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'product-session', fetch: boundary.clientFetch });
    expect(await client.messageReceipt('room one', receipt.clientNonce)).toEqual(receipt);
    expect(boundary.requests).toHaveLength(1);
  });
  test('missing authority stays a read error rather than an empty or successful receipt', async () => {
    const boundary = fetchBoundary(() => Response.json({ error: { code: 'not_found', message: 'Not recorded or not visible.', requestId: 'receipt_404', retrySafe: true } }, { status: 404 }));
    const client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: boundary.clientFetch });
    await expect(client.messageReceipt('room', 'missing_nonce_123456')).rejects.toMatchObject({ code: 'not_found', outcomeUnknown: false, requestId: 'receipt_404' });
    expect(boundary.requests).toHaveLength(1);
  });
});
