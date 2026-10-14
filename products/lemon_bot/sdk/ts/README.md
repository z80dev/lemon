# Lemon Bot TypeScript SDK

Dependency-free browser/Bun REST and realtime client for the product backend, not the Lemon operator socket. Wire types are imported and reexported directly from `../../contracts/protocol.ts`; there is no second endpoint catalog, demo data, offline mutation queue or automatic mutation retry. This workspace package exports TypeScript source for Bun and bundlers.

## REST and explicit intent

```ts
import { LemonBotClient, LemonBotError, nonce } from '@lemon-bot/sdk';

const client = new LemonBotClient({
  baseUrl: 'https://bot.example', // origin or a /v1 base; client.baseUrl is normalized
  token: productSessionToken,
});
const bot = await client.call('GET /bots/:id', { params: { id: botId } });
const updated = await client.call('PATCH /bots/:id', {
  params: { id: bot.id },
  body: { revision: bot.revision, clientNonce: nonce(), name: 'Finance' },
});
```

`call` only accepts canonical `RestKey` keys. Required path names, body, required query fields and the exact response are derived from `RestEndpoints`. Optional list queries may be omitted; a required query such as `GET /search` cannot. Undefined body means no body, not `{}`. IDs are percent-encoded and cannot contain `/`. Array query filters use commas; booleans and numbers retain their canonical wire encoding. `signal` accepts an AbortSignal. Non-loopback URLs require HTTPS. A fresh client can represent another backend/account; this client never writes tokens into URLs, logs, cookies or persistent storage.

Every explicit mutation carries the request type's nonce and, for updates, the current resource revision. The SDK does not silently invent these for the caller. Password/secret/auth requests are never replayed. Hooks use the sole `/hooks/:routineId` prefix exception outside `/v1`; use a separate client whose token is the current routine key, never the user or operator credential. SCIM uses a separate scoped integration token, `application/scim+json`, and required `ifMatch` options on existing Users/Groups PUT/PATCH/DELETE. Obtain its strong version from the fetched resource's `meta.version`. OIDC callback redirects return `{status:302,location}` without following the redirect or sending credentials to its target.

### Errors, unknown outcomes and revisions

```ts
const clientNonce = nonce();
try {
  await client.call('POST /conversations/:id/messages', {
    params: { id: conversationId }, body: { clientNonce, text: draftText },
  });
} catch (error) {
  if (!(error instanceof LemonBotError)) throw error;
  if (error.outcomeUnknown) {
    // Retain unsent UI input and the original intent/nonce. No resend here.
    const runs = await client.reconcileRuns(clientNonce, { conversationId });
    // Inspect run statuses; an empty result is not proof nothing happened.
    // GET error.resourceIds through the corresponding authorized resource routes.
  } else if (error.code === 'revision_conflict') {
    // Inspect error.currentRevision/currentResource, GET the resource, review changes.
    // Do not overwrite another device's update or blindly replay the old request.
  }
}
```

`LemonBotError` exposes `code`, `message`, `requestId`, `status`, `retrySafe`, `details`, `outcomeUnknown`, `clientNonce`, `resourceIds`, `currentRevision` and `currentResource`. `status:0` means no HTTP response. Reserved IDs and server details survive errors. A network loss or unreadable receipt after mutation dispatch is `outcome_unknown`, with `retrySafe:false`; an authoritative 2xx receipt containing an unknown outcome is also rejected as `LemonBotError`, with its receipt in `currentResource`. A signal already aborted before dispatch is not an unknown mutation. Offline/read errors reject and never become empty collections. `retrySafe` is server information, not permission for the SDK to repeat anything. Reconciliation is explicit GET only; unknown resource/run states remain unknown until verified.

## Real attachment bytes and voice

```ts
const attachment = await client.upload(fileBlob, {
  clientNonce: nonce(), purpose: 'message', conversationId,
}, 'report.pdf');
const download = await client.download(attachment.id);
const bytes = await client.downloadBytes(download);
const segment = await client.downloadBytes(download, {
  range: { start: 0, end: 1023 }, // inclusive end; omitted end means through EOF
});

const transcript = await client.transcribe(audioBlob, {
  clientNonce: nonce(), purpose: 'audio', conversationId,
}, { clientNonce: nonce(), language: 'en' }, 'microphone.webm');
// Review/edit transcript.text before an explicit ordinary message Send.
```

Uploads are multipart with exactly `metadata` JSON and a binary `file` part; the fetch implementation generates the correct multipart boundary. `call('POST /attachments', {body: metadata,file: blob,filename?,signal?})` is the abortable equivalent. No base64 metadata pretending to be a file, storage path or metadata-only upload. Audio uses the same actual bytes upload, then the canonical transcription endpoint; STT never implicitly sends a message. TTS uses typed `POST /audio/speech` or bot voice preview and the real returned download. Live voice utterances use ordinary messages with `voiceSessionId`, not raw binary WS frames.

Signed download URLs are accepted only on the configured backend origin and its `/v1/downloads/:ticket` path, before expiration. The binary request always omits bearer and cookies and refuses redirects. Do not persist or log tickets. `downloadBytes` supports a single byte range and propagates 416/expired/revoked errors. `call('GET /downloads/:ticket', {params:{ticket},range?})` also returns Uint8Array without bearer. Browser players may use a freshly authorized trusted ticket with no-referrer handling; untrusted HTML still requires a sandbox in the consuming UI.

## Realtime: apply, persist, then acknowledge

```ts
import { reduceEntryEvent, type TranscriptEntry } from '@lemon-bot/sdk';

let entries: TranscriptEntry[] = [];
const realtime = client.realtime({
  deviceId,
  // Supply a saved cursor only together with its already-applied account/workspace cache.
  onReset: async () => {
    const snapshot = await client.call('GET /sync');
    replaceWorkspaceState(snapshot);
    // Page each hasMore collection; fetch selected transcript/required history here.
    entries = await loadSelectedHistory();
    return snapshot; // its atomic cursor, never the ready watermark
  },
  onEvent: async event => {
    if (event.event === 'entry.upserted' || event.event === 'entry.deleted' || event.event === 'entry.delta') {
      entries = await reduceEntryEvent(entries, event,
        id => client.call('GET /entries/:id', { params: { id } }));
      await persistTranscript(entries);
    } else {
      await applyWorkspaceEvent(event);
    }
  },
  saveCursor: cursor => persistAccountBoundCursor(cursor),
  onState: (state, error) => showConnectionState(state, error),
});
realtime.start(); // void; authentication/sync/replay are asynchronous states
const unsubscribe = realtime.subscribe(frame => {
  // terminal_output, terminal_gap, terminal_exit, typing and other server frames
});
// On logout/unmount:
unsubscribe();
realtime.close();
```

The first socket frame is auth. No subscription is sent until ready acknowledges authentication; subscribe responses are correlated to the exact requestId. With no existing cache cursor, `onReset` must replace derived state and return a real atomic GET /sync snapshot. Cursor expiration invokes the same reset path and waits for its application/persistence before resubscribing. The SDK serializes event application, frame listeners and cursor persistence, then sends ack. Application/persistence failure preserves the previous safe cursor and reconnects; later watermarks cannot overtake an unfinished event. Consumers should make event application idempotent by resource ID/revision because interrupted application can be delivered again.

Cursors compare as unsigned decimal bigint; ACL-filtered gaps are valid. `compareCursors` is only for realtime sequence cursors, never signed REST pagination cursors. `upsertRevision` and `mergeRevisions` reject stale revisions. `applyEntryDelta` checks UTF-16 code-unit offsets (JS string length), conversation, entry and run; contained identical replay is ignored, missing/overlapping mismatched text requires reconciliation. `reduceEntryEvent` awaits GET on those gaps, propagates read failure, replaces provisional text with authoritative GET even at the same revision, and only a full final upsert closes streaming.

Connection states: `connecting`, `authenticating`, `syncing`, `replaying`, `live`, `reconnecting`, `unauthenticated`, `forbidden`, `error`, `closed`. Authentication/revocation closes are terminal; user login must establish a new valid session. Heartbeat uses protocol ping/pong and disconnects after 60 seconds without activity. Reconnect reauthenticates and resumes from the safe applied cursor, never replays REST requests or WS voice/typing/presence commands. `send` transmits now or throws; nothing is queued offline. Explicit changed conversation selection requires a prior safe snapshot cursor and refetch of any added conversation's missing history. Do not treat last ack as proof skipped conversations were loaded.

Terminal listeners receive gap/exit frames including nullable exit codes. `terminal_subscribe` is the only terminal command resumed, from the last fully applied output sequence. Input/resize/close remain typed REST calls with explicit nonces and are never replayed. Terminal output has its own number sequence, separate from the durable workspace cursor.

## Checks

From this package directory, after dependencies are provisioned:

```sh
bun run check
bun run test
```

Consumer tests exercise encoded REST requests, revisions/nonces/errors, actual multipart and binary/range responses, signed-origin credential isolation, voice upload/STT, uncertain outcomes and GET reconciliation, ordered async socket application/persistence/ack, cursor reset/reconnect/auth revocation, heartbeat and terminal reattachment without mutation replay. No source-text/wiring assertions. These commands were not run in the parallel implementation slice; the integrating lead owns verification.
