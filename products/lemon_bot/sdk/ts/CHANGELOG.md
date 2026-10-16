# Changelog

## [Unreleased]

### Added

- Export the shared read-only Bot origin preflight and product/workspace identity validators. Strict pairing links now require an `instance` fingerprint alongside `backend`, `cluster` and `code`; three-key links are rejected.
- Add shared typed `ProviderDeviceLoginRequest`, `ProviderDeviceLoginStatus` and safe `ProviderDeviceLogin` contracts plus canonical controller/named-machine start, poll and cancel REST keys. Start's fixed nonce is the login ID; polling and cancellation use that route ID with separate fixed nonces and reconcile fresh target state. No credential/token fields are exposed.
- Instance status now includes build, channel details, provider credential health and explicit runtime actions/via; the shared wire fixture covers controller lifecycle and all credential states.
- Add `InstanceStatus`, controller-link and runtime lifecycle contracts with typed `instance()`, `reconnectController()` and `runtimeAction(action, confirm)` helpers. Actions retain nonce-based mutation handling; lifecycle completion is polled through instance status. Include a backend-produced instance JSON fixture and consumer tests.

### Changed

- Migrate to canonical named owner-only Bot/conversation/memory/skill/connector types. Remove obsolete cross-human group departure callers; retain own-Bot group admission and unknown-outcome reconciliation.
- Add strict `parsePairUrl` returning canonical `PairingLink`, with bounded exact-origin HTTPS/loopback validation and no credential-bearing URL acceptance or secret echo in errors.
- Add actual pairing boundary tests for owner issuance/approval/read state, anonymous preview/claim/completion, fixed nonces, no automatic replay and nullable device-bound session expiry.
- Treat canonical non-consuming pairing preview POST as a read for interrupted-response errors; all real mutation unknown-outcome, URL isolation and authoritative realtime cursor behavior remains unchanged.

## [1.0.0]

- Canonical typed product REST calls derive path parameters, body, query and responses directly from RestEndpoints; SCIM media/If-Match, hook prefixes, OIDC redirects and binary responses retain their transport exceptions.
- Root backend URLs normalize directly to `/v1` without a duplicate slash; HTTP and realtime transports share the same canonical base.
- Explicit nonce/revision intents and structured errors retain request IDs, current resources/revisions and uncertain reserved IDs. Network mutation loss and unknown receipts require GET reconciliation; there is no mutation retry or offline queue.
- Attachments upload actual multipart file bytes; signed backend-only downloads omit credentials, refuse redirects and support byte ranges. Voice transcription uploads real audio before STT and never sends chat implicitly.
- Realtime authenticates before correlated subscriptions, resets from atomic snapshots, serializes async event/frame application and persistence before acknowledgment, resumes bigint cursors and terminal output only, and exposes heartbeat/auth/revocation lifecycle states.
- Revision-aware resource merging and offset-safe transcript reduction reconcile missing text with authoritative GET rather than blind append.
- Mixed group receipts preserve proven rejected targets separately from admitted work. Refusal errors retain saved entry/run IDs and nonce for GET-only reconciliation; no refused target is automatically retried.
- Add Owner-only read-only account teardown observation, preserving fixed conflict IDs and separate product/provider cleanup outcomes without automatic mutation replay.
- Consumer boundary tests cover fetch serialization/binary/errors/unknowns, voice, realtime ordering/reset/reconnect/auth/heartbeat, terminal reattachment and no mutation replay. Verification commands are provided for the integrating lead; they were not run during parallel slice implementation.
