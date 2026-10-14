import { describe, expect, test } from 'bun:test';
import { LemonBotClient, LemonBotError, nonce } from '../src/index.ts';
import type { AccountTeardown, Download, MessageReceipt, Run } from '../src/index.ts';
import { attachment, entry, fetchBoundary, snapshot } from './fixtures.ts';

const origin = 'https://bot.example';

describe('typed client at the fetch boundary', () => {
  test('canonical path substitution, comma filters, boolean queries and absent GET body', async () => {
    const boundary = fetchBoundary(request => {
      const url = new URL(request.url);
      expect(url.pathname).toBe('/v1/search');
      expect(url.searchParams.get('q')).toBe('a & b');
      expect(url.searchParams.get('kinds')).toBe('message,file');
      expect(url.searchParams.get('limit')).toBe('25');
      expect(request.body).toBeNull();
      expect(request.headers.get('Authorization')).toBe('Bearer user-session');
      expect(request.redirect).toBe('manual');
      expect(request.credentials).toBe('omit');
      return Response.json({ items: [], nextCursor: null });
    });
    const client = new LemonBotClient({ baseUrl: `${origin}/`, token: 'user-session', fetch: boundary.clientFetch });
    expect(client.baseUrl).toBe(`${origin}/v1`);
    expect(await client.call('GET /search', { query: { q: 'a & b', kinds: ['message', 'file'], limit: 25 } })).toEqual({ items: [], nextCursor: null });
    const second = fetchBoundary(request => {
      expect(new URL(request.url).pathname).toBe('/v1/bots/id%20%3F%23');
      return Response.json({ id: 'id ?#' });
    });
    await new LemonBotClient({ baseUrl: `${origin}/v1/`, fetch: second.clientFetch }).call('GET /bots/:id', { params: { id: 'id ?#' } });
    const third = fetchBoundary(request => {
      expect(new URL(request.url).searchParams.get('hidden')).toBe('false');
      return Response.json({ items: [], nextCursor: null });
    });
    await new LemonBotClient({ baseUrl: origin, fetch: third.clientFetch }).call('GET /bots', { query: { hidden: false } });
  });

  test('revision, nonce and exact JSON survive the wire without implicit defaults', async () => {
    const intent = { revision: 7, clientNonce: nonce(), displayName: 'New name' };
    const boundary = fetchBoundary(async request => {
      expect(request.method).toBe('PATCH');
      expect(request.headers.get('Content-Type')).toBe('application/json');
      expect(await request.json()).toEqual(intent);
      return Response.json({ ...snapshot.user, revision: 8, displayName: 'New name' });
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    const user = await client.call('PATCH /me', { body: intent });
    expect(user.revision).toBe(8);
    expect(boundary.requests).toHaveLength(1);
    expect(intent.clientNonce).toMatch(/^[a-zA-Z0-9_-]{16,128}$/);
  });

  test('multipart carries exactly metadata and actual original bytes', async () => {
    const bytes = new Uint8Array([0, 255, 3, 10]);
    const metadata = { clientNonce: nonce(), purpose: 'message' as const, conversationId: 'conversation_1' };
    const boundary = fetchBoundary(async request => {
      expect(request.headers.get('Content-Type')).toMatch(/^multipart\/form-data; boundary=/);
      const form = await request.formData();
      expect([...form.keys()]).toEqual(['metadata', 'file']);
      expect(JSON.parse(String(form.get('metadata')))).toEqual(metadata);
      const file = form.get('file') as File;
      expect(file.name).toBe('original.bin');
      expect(new Uint8Array(await file.arrayBuffer())).toEqual(bytes);
      return Response.json(attachment, { status: 201 });
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    expect((await client.upload(new Blob([bytes]), metadata, 'original.bin')).id).toBe(attachment.id);
  });

  test('signed range downloads and canonical binary calls never carry bearer or cookies', async () => {
    const download: Download = { url: `${origin}/v1/downloads/ticket`, expiresAtMs: Date.now() + 60000, filename: 'file', mime: 'application/octet-stream', size: 4 };
    const boundary = fetchBoundary(request => {
      expect(request.headers.get('Authorization')).toBeNull();
      expect(request.credentials).toBe('omit');
      expect(request.referrerPolicy).toBe('no-referrer');
      expect(request.redirect).toBe('manual');
      expect(request.headers.get('Range')).toBe('bytes=1-2');
      return new Response(new Uint8Array([255, 0]), { status: 206, headers: { 'Content-Type': 'application/octet-stream' } });
    });
    const client = new LemonBotClient({ baseUrl: origin, token: 'never-leak', fetch: boundary.clientFetch });
    expect(await client.downloadBytes(download, { range: { start: 1, end: 2 } })).toEqual(new Uint8Array([255, 0]));
    expect(await client.call('GET /downloads/:ticket', { params: { ticket: 'ticket' }, range: { start: 1, end: 2 } })).toEqual(new Uint8Array([255, 0]));
    await expect(client.downloadBytes({ ...download, url: 'https://evil.example/v1/downloads/ticket' })).rejects.toMatchObject({ code: 'forbidden' });
    await expect(client.downloadBytes({ ...download, expiresAtMs: 1 })).rejects.toMatchObject({ code: 'expired' });
    await expect(client.downloadBytes(download, { range: { start: 3, end: 2 } })).rejects.toMatchObject({ code: 'invalid_request' });
    expect(boundary.requests).toHaveLength(2);
  });

  test('download authorization fetch and binary HTTP errors stay explicit', async () => {
    const download: Download = { url: `${origin}/v1/downloads/ticket`, expiresAtMs: Date.now() + 60000, filename: 'file', mime: 'application/pdf', size: 100 };
    const boundary = fetchBoundary(request => {
      if (new URL(request.url).pathname.endsWith('/download')) {
        expect(request.headers.get('Authorization')).toBe('Bearer session');
        return Response.json(download);
      }
      return Response.json({ error: { code: 'invalid_request', message: 'Invalid range.', requestId: 'range_1', retrySafe: true } }, { status: 416 });
    });
    const client = new LemonBotClient({ baseUrl: origin, token: 'session', fetch: boundary.clientFetch });
    expect(await client.download('attachment_1')).toEqual(download);
    await expect(client.downloadBytes(download, { range: { start: 1000 } })).rejects.toMatchObject({ status: 416, requestId: 'range_1', code: 'invalid_request' });
  });

  test('download redirects are not followed to another origin', async () => {
    const boundary = fetchBoundary(() => new Response(null, { status: 302, headers: { Location: 'https://evil.example/blob' } }));
    const client = new LemonBotClient({ baseUrl: origin, token: 'session', fetch: boundary.clientFetch });
    await expect(client.downloadBytes({ url: `${origin}/v1/downloads/ticket`, expiresAtMs: Date.now() + 1000, filename: 'file', mime: 'text/plain', size: 2 })).rejects.toBeInstanceOf(LemonBotError);
    expect(boundary.requests).toHaveLength(1);
  });

  test('server error preserves diagnostics, current resource/revision and reserved IDs', async () => {
    const boundary = fetchBoundary(() => Response.json({ error: {
      code: 'revision_conflict', message: 'Changed.', requestId: 'req_1', retrySafe: true,
      details: { currentRevision: 4, currentResource: { id: 'bot_1', revision: 4 }, resourceIds: ['bot_1'], runId: 'run_1' },
    } }, { status: 409 }));
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    await expect(client.call('PATCH /bots/:id', { params: { id: 'bot_1' }, body: { revision: 3, clientNonce: 'nonce_123456789012', name: 'Name' } })).rejects.toMatchObject({
      code: 'revision_conflict', requestId: 'req_1', status: 409, retrySafe: true, currentRevision: 4,
      currentResource: { id: 'bot_1', revision: 4 }, resourceIds: ['bot_1', 'run_1'], clientNonce: 'nonce_123456789012', outcomeUnknown: false,
    });
  });

  test('network mutation failure never retries and explicit nonce reconciliation is GET', async () => {
    const clientNonce = nonce();
    const boundary = fetchBoundary(request => {
      if (request.method === 'POST') throw new TypeError('Network lost after dispatch');
      expect(new URL(request.url).pathname).toBe('/v1/runs');
      expect(new URL(request.url).searchParams.get('clientNonce')).toBe(clientNonce);
      return Response.json({ items: [], nextCursor: null });
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    await expect(client.call('POST /conversations/:id/messages', { params: { id: 'conversation_1' }, body: { text: 'Send once', clientNonce } })).rejects.toMatchObject({ code: 'outcome_unknown', retrySafe: false, outcomeUnknown: true, clientNonce, resourceIds: ['conversation_1'] });
    expect(boundary.requests).toHaveLength(1);
    await client.reconcileRuns(clientNonce);
    expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET']);
  });

  test('offline reads are failures, aborted-before-dispatch is not an unknown mutation', async () => {
    const boundary = fetchBoundary(() => { throw new TypeError('offline'); });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    await expect(client.call('GET /bots')).rejects.toMatchObject({ code: 'upstream_unavailable', outcomeUnknown: false });
    const signal = AbortSignal.abort();
    await expect(client.call('POST /auth/logout', { body: { clientNonce: nonce() }, signal })).rejects.toMatchObject({ code: 'invalid_request', outcomeUnknown: false });
    expect(boundary.requests).toHaveLength(1);
  });

  test('202 unknown receipt and truncated successful receipt do not become success', async () => {
    const responses = [Response.json({ status: 'outcome_unknown', clientNonce: 'nonce', runs: [{ id: 'run_1', status: 'outcome_unknown' }], entries: [{ id: 'entry_1' }], delivery: [] }, { status: 202 }), new Response('{', { status: 202 })];
    const boundary = fetchBoundary(() => responses.shift()!);
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    const intent = { params: { id: 'conversation_1' }, body: { text: 'Send', clientNonce: nonce() } };
    await expect(client.call('POST /conversations/:id/messages', intent)).rejects.toMatchObject({ code: 'outcome_unknown', resourceIds: ['run_1', 'entry_1', 'conversation_1'], status: 202 });
    await expect(client.call('POST /conversations/:id/messages', intent)).rejects.toMatchObject({ code: 'outcome_unknown', status: 202 });
    expect(boundary.requests).toHaveLength(2);
  });

  test('voice fallback uploads bytes then STT attachment ID without sending messages', async () => {
    const boundary = fetchBoundary(async request => {
      if (new URL(request.url).pathname === '/v1/attachments') {
        const form = await request.formData();
        expect(JSON.parse(String(form.get('metadata'))).purpose).toBe('audio');
        expect(new Uint8Array(await (form.get('file') as File).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
        return Response.json(attachment);
      }
      expect(new URL(request.url).pathname).toBe('/v1/audio/transcriptions');
      expect(await request.json()).toEqual({ clientNonce: 'stt_12345678901234', attachmentId: 'attachment_1', language: 'en' });
      return Response.json({ text: 'Review before send', language: 'en', durationMs: 1000, segments: [] });
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    const result = await client.transcribe(new Blob([new Uint8Array([1, 2, 3, 4])], { type: 'audio/webm' }), { clientNonce: nonce(), purpose: 'audio', conversationId: 'conversation_1' }, { clientNonce: 'stt_12345678901234', language: 'en' }, 'mic.webm');
    expect(result.text).toBe('Review before send');
    expect(boundary.requests).toHaveLength(2);
  });

  test('hook prefix exception, OIDC manual redirect and SCIM headers/204 are canonical', async () => {
    const boundary = fetchBoundary(request => {
      const url = new URL(request.url);
      if (url.pathname.startsWith('/hooks/')) return Response.json({ accepted: true, status: 'accepted', routineRun: { id: 'routine_run_1' } });
      if (url.pathname.includes('/auth/oidc/callback/')) return new Response(null, { status: 302, headers: { Location: 'lemonbot://auth/complete?completionCode=one-use' } });
      expect(request.headers.get('If-Match')).toBe('"revision-3"');
      expect(request.headers.get('Accept')).toBe('application/scim+json');
      return new Response(null, { status: 204 });
    });
    const client = new LemonBotClient({ baseUrl: origin, token: 'scoped-token', fetch: boundary.clientFetch });
    await client.call('POST /hooks/:routineId', { params: { routineId: 'routine_1' }, body: { clientNonce: nonce() } });
    expect(new URL(boundary.requests[0]!.url).pathname).toBe('/hooks/routine_1');
    expect(await client.call('GET /auth/oidc/callback/:providerId', { params: { providerId: 'oidc_1' }, query: { state: 'state', code: 'code' } })).toEqual({ status: 302, location: 'lemonbot://auth/complete?completionCode=one-use' });
    expect(await client.call('DELETE /scim/v2/Users/:id', { params: { id: 'user_1' }, ifMatch: '"revision-3"' })).toBeUndefined();
  });

  test('mixed group receipt preserves proven rejection without fencing admitted work', async () => {
    const clientNonce = nonce();
    const refused: Run = {
      id: 'run_refused', revision: 1, createdAtMs: 1, updatedAtMs: 2,
      conversationId: 'conversation_1', botId: 'bot_refused', initiatorUserId: 'user_1',
      clientNonce, status: 'failed', startedAtMs: null, completedAtMs: 2, routineRunId: null,
      error: { code: 'policy_denied', message: 'Spend ceiling reached.', requestId: 'admission_1', retrySafe: true },
    };
    const admitted: Run = { ...refused, id: 'run_admitted', botId: 'bot_admitted', status: 'running', error: null, startedAtMs: 2, completedAtMs: null };
    const receipt: MessageReceipt = {
      clientNonce, status: 'accepted',
      entries: [{ ...entry, clientNonce, actor: { kind: 'user', id: 'user_1', displayName: 'Owner' }, role: 'user', text: 'Compare both reports', streaming: false, runId: null }],
      runs: [admitted, refused],
      delivery: [
        { botId: admitted.botId, requestedMode: 'followup', effectiveMode: 'started', targetRunId: null, runId: admitted.id },
        { botId: refused.botId, requestedMode: 'followup', effectiveMode: 'rejected', targetRunId: null, runId: refused.id },
      ],
    };
    const boundary = fetchBoundary(() => Response.json(receipt, { status: 202 }));
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    const actual = await client.call('POST /conversations/:id/messages', { params: { id: 'conversation_1' }, body: { text: 'Compare both reports', clientNonce } });
    expect(actual).toEqual(receipt);
    expect(actual.runs.find(run => run.id === actual.delivery[1]!.runId)?.error?.code).toBe('policy_denied');
    expect(actual.delivery[0]?.effectiveMode).toBe('started');
    expect(boundary.requests).toHaveLength(1);
  });

  test('zero-admission refusal retains saved entry/run IDs and reconciles by GET without replay', async () => {
    const clientNonce = nonce();
    const boundary = fetchBoundary(request => {
      if (request.method === 'POST') return Response.json({ error: {
        code: 'policy_denied', message: 'No target admitted.', requestId: 'refusal_1', retrySafe: true,
        details: { entryIds: ['entry_refused'], runIds: ['run_refused'], clientNonce },
      } }, { status: 403 });
      expect(new URL(request.url).pathname).toBe('/v1/runs');
      expect(new URL(request.url).searchParams.get('clientNonce')).toBe(clientNonce);
      return Response.json({ items: [], nextCursor: null });
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    await expect(client.call('POST /conversations/:id/messages', { params: { id: 'conversation_1' }, body: { text: 'Start if allowed', clientNonce } })).rejects.toMatchObject({
      code: 'policy_denied', outcomeUnknown: false, retrySafe: true, clientNonce,
      resourceIds: ['entry_refused', 'run_refused', 'conversation_1'], requestId: 'refusal_1',
    });
    await client.reconcileRuns(clientNonce);
    expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET']);
  });

  test('explicit group departure sends the chosen successor and receives raw Empty', async () => {
    const body = { clientNonce: nonce(), newOwnerUserId: 'remaining_human' };
    const boundary = fetchBoundary(async request => {
      expect(request.method).toBe('POST');
      expect(new URL(request.url).pathname).toBe('/v1/conversations/group%20id/leave');
      expect(await request.json()).toEqual(body);
      return Response.json({ ok: true });
    });
    const client = new LemonBotClient({ baseUrl: origin, token: 'own-session', fetch: boundary.clientFetch });
    expect(await client.call('POST /conversations/:id/leave', { params: { id: 'group id' }, body })).toEqual({ ok: true });
    expect(boundary.requests).toHaveLength(1);
  });

  test('group leave conflict keeps fixed run IDs for reads and does not replay after terminal evidence', async () => {
    const body = { clientNonce: nonce() };
    const stopped: Run = { id: 'owned_run', revision: 2, createdAtMs: 1, updatedAtMs: 3, conversationId: 'group_1',
      botId: 'bot_1', initiatorUserId: 'user_1', clientNonce: 'original_work_nonce', status: 'cancelled',
      error: null, startedAtMs: 1, completedAtMs: 3, routineRunId: null };
    const boundary = fetchBoundary(request => {
      if (request.method === 'POST') return Response.json({ error: {
        code: 'conflict', message: 'Owned work is not yet terminal; membership retained.',
        requestId: 'leave_1', retrySafe: false, details: { runIds: ['owned_run'] },
      } }, { status: 409 });
      expect(new URL(request.url).pathname).toBe('/v1/runs/owned_run');
      return Response.json(stopped);
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    await expect(client.call('POST /conversations/:id/leave', { params: { id: 'group_1' }, body })).rejects.toMatchObject({
      code: 'conflict', outcomeUnknown: false, requestId: 'leave_1', clientNonce: body.clientNonce,
      resourceIds: ['owned_run', 'group_1'],
    });
    expect((await client.call('GET /runs/:id', { params: { id: 'owned_run' } })).status).toBe('cancelled');
    expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET']);
  });

  test('Owner cleanup observation is read-only and preserves distinct product/provider uncertainty', async () => {
    const record: AccountTeardown = {
      id: 'teardown_1', revision: 3, createdAtMs: 1, updatedAtMs: 3, operation: 'delete_account',
      userId: 'deleted_user', workspaceId: 'workspace_1', state: 'outcome_unknown', requestId: 'delete_request',
      startedAtMs: 1, completedAtMs: null,
      productCleanup: { state: 'completed', updatedAtMs: 2, errorCode: null },
      providerCleanup: [{ providerId: 'registered_mail_provider', kind: 'email', receiptId: 'receipt_1',
        state: 'outcome_unknown', updatedAtMs: 3, errorCode: 'upstream_unavailable' }],
    };
    const boundary = fetchBoundary(request => {
      expect(request.method).toBe('GET');
      expect(request.headers.get('Authorization')).toBe('Bearer owner-session');
      expect(request.body).toBeNull();
      const url = new URL(request.url);
      if (url.pathname === '/v1/account-teardowns') {
        expect(url.searchParams.get('userId')).toBe(record.userId);
        expect(url.searchParams.get('state')).toBe('outcome_unknown');
        return Response.json({ items: [record], nextCursor: null });
      }
      expect(url.pathname).toBe('/v1/account-teardowns/teardown_1');
      return Response.json(record);
    });
    const client = new LemonBotClient({ baseUrl: origin, token: 'owner-session', fetch: boundary.clientFetch });
    const page = await client.call('GET /account-teardowns', { query: { userId: record.userId, state: 'outcome_unknown' } });
    expect(page.items[0]?.productCleanup.state).toBe('completed');
    expect(page.items[0]?.providerCleanup[0]?.state).toBe('outcome_unknown');
    expect(await client.call('GET /account-teardowns/:id', { params: { id: record.id } })).toEqual(record);
    expect(boundary.requests.map(request => request.method)).toEqual(['GET', 'GET']);
  });
});
