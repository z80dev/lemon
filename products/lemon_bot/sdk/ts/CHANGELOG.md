# Changelog

## 1.0.0

- Canonical typed product REST calls derive path parameters, body, query and responses directly from RestEndpoints; SCIM media/If-Match, hook prefixes, OIDC redirects and binary responses retain their transport exceptions.
- Explicit nonce/revision intents and structured errors retain request IDs, current resources/revisions and uncertain reserved IDs. Network mutation loss and unknown receipts require GET reconciliation; there is no mutation retry or offline queue.
- Attachments upload actual multipart file bytes; signed backend-only downloads omit credentials, refuse redirects and support byte ranges. Voice transcription uploads real audio before STT and never sends chat implicitly.
- Realtime authenticates before correlated subscriptions, resets from atomic snapshots, serializes async event/frame application and persistence before acknowledgment, resumes bigint cursors and terminal output only, and exposes heartbeat/auth/revocation lifecycle states.
- Revision-aware resource merging and offset-safe transcript reduction reconcile missing text with authoritative GET rather than blind append.
- Consumer boundary tests cover fetch serialization/binary/errors/unknowns, voice, realtime ordering/reset/reconnect/auth/heartbeat, terminal reattachment and no mutation replay. Verification commands are provided for the integrating lead; they were not run during parallel slice implementation.
