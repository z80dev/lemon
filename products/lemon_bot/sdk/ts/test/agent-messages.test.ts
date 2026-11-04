import { expect, test } from 'bun:test';
import { LemonBotClient } from '../src/index.ts';
import { fetchBoundary } from './fixtures.ts';

const receipt = { messageId: 'fixed-message', sourceId: 'bot://instance/source', targetId: 'session://target', status: 'outcome_unknown' as const, runId: null, response: null };

test('unknown addressed send preserves correlation and reconciles by GET without replay', async () => {
  const boundary = fetchBoundary(() => Response.json(receipt));
  const client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: boundary.clientFetch });
  await expect(client.messageAgent('source', { clientNonce: receipt.messageId, target: '@bob', text: 'Question' })).rejects.toMatchObject({
    outcomeUnknown: true, clientNonce: receipt.messageId, currentResource: receipt,
    resourceIds: expect.arrayContaining([receipt.messageId, receipt.sourceId, receipt.targetId]),
  });
  expect(boundary.requests).toHaveLength(1);
  expect(await client.agentMessage('source', receipt.messageId)).toEqual(receipt);
  expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET']);
});

test('lost send is not replayed and an absent receipt remains a read failure', async () => {
  const boundary = fetchBoundary(request => {
    if (request.method === 'POST') throw new TypeError('Disconnected');
    return Response.json({ error: { code: 'not_found', message: 'Message not found.', requestId: 'read-id', retrySafe: true } }, { status: 404 });
  });
  const client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: boundary.clientFetch });
  await expect(client.messageAgent('source', { clientNonce: 'fixed', target: '@bob', text: 'Question' })).rejects.toMatchObject({ outcomeUnknown: true, clientNonce: 'fixed' });
  await expect(client.agentMessage('source', 'fixed')).rejects.toMatchObject({ code: 'not_found', outcomeUnknown: false });
  expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET']);
});
