# Lemon Bot TypeScript SDK

Browser/Bun REST and realtime client for the owner-only product backend, not the Lemon operator socket. Explicit named wire types are imported and reexported directly from `../../contracts/protocol.ts`; there is no second endpoint catalog, demo data, offline mutation queue or automatic mutation retry. This workspace package exports TypeScript source for Bun and bundlers. Every live Bot belongs only to its human owner; workspace/admin roles never grant another user's live Bot, history or credentials.

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

Origin and `/v1` base URLs, with or without trailing slashes, normalize to a single `/v1` path before endpoint paths are appended.

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
    const receipt = await client.messageReceipt(conversationId, clientNonce);
    // Only a complete receipt accounts for every original group target.
    // Unknown/missing receipts retain the nonce fence; rejected targets retain their run errors.
  } else if (error.code === 'revision_conflict') {
    // Inspect error.currentRevision/currentResource, GET the resource, review changes.
    // Do not overwrite another device's update or blindly replay the old request.
  }
}
```

`LemonBotError` exposes `code`, `message`, `requestId`, `status`, `retrySafe`, `details`, `outcomeUnknown`, `clientNonce`, `resourceIds`, `currentRevision` and `currentResource`. `status:0` means no HTTP response. Reserved IDs and server details survive errors. A network loss or unreadable receipt after mutation dispatch is `outcome_unknown`, with `retrySafe:false`; an authoritative 2xx receipt containing an unknown outcome is also rejected as `LemonBotError`, with its receipt in `currentResource`. A signal already aborted before dispatch is not an unknown mutation. Offline/read errors reject and never become empty collections. `retrySafe` is server information, not permission for the SDK to repeat anything. Ordinary resource reconciliation is explicit GET only; the documented pairing issuance/completion receipt reconciliations require a separate explicit same-nonce request. Unknown resource/run states remain unknown until verified.

A mixed **own-Bot group** receipt may contain `delivery.effectiveMode:"rejected"` while other owned targets are admitted. Inspect the referenced `receipt.runs` row’s error. Correcting a prerequisite does not automatically resend the recorded message or admitted targets. Groups have one human owner and 2–6 Bots owned by that same user.

## Desktop-to-iPhone pairing

```ts
import { LemonBotClient, nonce, parsePairUrl, type PairingIssued } from '@lemon-bot/sdk';

// Existing authenticated owner client: the browser keeps its ordinary product session.
const startNonce = nonce();
const issued: PairingIssued = await ownerClient.call('POST /pairings', {
  body: { clientNonce: startNonce },
});
// Render issued.pairUrl locally as a real QR, in transient screen memory only.
const requests = await ownerClient.call('GET /pairings'); // Pairing[], safe state only
const pending = requests.find(request => request.status === 'pending_approval');
if (pending?.verificationCode) {
  // Only after the owner explicitly compares the phone's six-digit code:
  const approveNonce = nonce();
  await ownerClient.call('POST /pairings/:id/approve', {
    params: { id: pending.id },
    body: { clientNonce: approveNonce, revision: pending.revision,
      verificationCode: pending.verificationCode },
  });
}

// Phone/native consumers parse strictly and use an anonymous client for public steps.
const link = parsePairUrl(scannedLink);
const phoneClient = new LemonBotClient({ baseUrl: link.backendUrl });
const preview = await phoneClient.call('POST /pairings/preview', {
  body: { pairCode: link.pairCode, workspaceId: link.workspaceId },
});
// Show preview.clusterName and exact preview.backendUrl before explicit Claim.
```

`parsePairUrl` returns canonical named `PairingLink`. It accepts only bounded `lemonbot://pair` links with exactly one `backend`, `cluster` and 43-character base64url `code`; no credentials, arbitrary route, fragment or additional query keys. Backend must be an exact HTTPS origin; loopback HTTP is only for same-machine development/Simulator. Tailscale reachability is a deployment prerequisite, never inferred from QR content. A localhost QR does not connect a physical iPhone to a desktop's localhost.

Preview is explicitly non-consuming, nonce-free read data despite using POST. Interrupted preview produces a read error, not an uncertain mutation. Claim, approval, denial, completion and revocation use explicit fixed mutation nonces. Owner refresh/polling uses only GET. Safe owner pairing resources/events never contain QR secret, claim token or session token. Never persist/log `pairUrl` or use an external QR image service; it exists only until claim, original five-minute expiry or the issuing screen closes. An explicit owner reconciliation can request the original issuance receipt with the **same** issuance nonce until that original deadline; it cannot extend expiry or reuse a consumed code. The SDK never performs that POST on its own.

Phone completion retains one fixed `PairingComplete.clientNonce` across pending observation and lost connected receipt reconciliation. Canonical `PairingCompletion` returns pending/denied/expired, or connected with the same device and product session. Private receipt replay is bounded to the original five-minute pairing deadline; a later attempt must re-pair. The resulting `AuthSession.expiresAtMs === null` means **until revoked**, not unknown/expired: show that coherently in device/session lists. Revoke through existing device/session endpoints; no refresh-token plane. Consumers store a paired phone's own bearer privately (Keychain on iOS), not the owner's browser token.

The SDK covers personally owned Bots, profile memory, skills and owned integrations. Owner OAuth authorization and native capability/tool-policy review apply. Workspace/Public templates create separate reviewed owned copies. Optional operator/admin APIs depend on server configuration.


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

Consumer tests exercise encoded REST requests, revisions/nonces/errors, multipart and binary/range responses, signed-origin credential isolation, voice upload/STT, uncertain outcomes and GET reconciliation, ordered socket application/persistence/ack, cursor reset/reconnect/auth revocation, heartbeat and terminal reattachment without mutation replay.


Owner account-cleanup observation uses only canonical `GET /account-teardowns` and `GET /account-teardowns/:id`. Recorded provider `outcome_unknown` remains typed read data, distinct from completed product cleanup; the SDK never interprets the ledger as authorization to repeat account deletion or provider revocation.
