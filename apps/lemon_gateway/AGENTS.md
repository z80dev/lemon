# LemonGateway contributor guide

Gateway owns optional SMS, voice and webhook ingress, enabled explicitly through
`:gateway_ingress_enabled`. Router owns execution; channels owns messaging
adapters. See [README](README.md).

## Ingress and idempotency

Prefer `lemon_channels` for new messaging platforms. Gateway ingress submits
`LemonCore.RunRequest` through `RouterBridge`, with stable session and run IDs.
Disabled ingress returns `:ignore` from startup; use shared binding resolution.

Webhook mutation boundaries are deliberately conservative:

- Derive `meta.channel_context` (`channel_id: "webhook"`) from the integration
  whose token authenticated the request, never from the payload; the router
  applies the `webhook` channel policy from it and refuses `:webhook` requests
  without it. Authentication is not content trust: classify the integration
  `peer_kind: :automation` (group approval floor) unless the operator's global
  config sets a literal `trusted_automation = true` on that integration.
- Reserve idempotency keys atomically before submission. Hash the caller's key
  with integration identity before any durable key, receipt or router request;
  reject blank/non-binary keys before hashing.
- `:outcome_unknown` may already have executed. Acknowledge HTTP delivery with a
  bounded uncertain receipt, fixed run ID and `retry_safe: false`, not a
  retryable 5xx. Mutation exceptions/exits are unknown, not definite rejection.
- Reservation/replay/receipt-store failures fail closed without claiming
  acceptance. Pending reservation and missing exact response are different
  states; never replay a generic success where the original response is unknown.
- Legacy raw-key migration first durably writes the hashed fence and exact
  response, then conditionally deletes raw records. Partial/concurrent migration
  cannot authorize replay. Legacy pending rows without run IDs remain ambiguous
  fences, not invented execution identities.
- Expiry removes response snapshots before primary fences on ordered backends;
  SQLite removes durable pairs transactionally. Failed cleanup neither permits
  replay nor advances the sweep watermark.
- Callback URLs are checked with `LemonCore.Net.Address` at submission (DNS
  failure is a rejection, metadata is refused even with
  `allow_private_callback_hosts`) and delivered only through
  `LemonCore.Net.HTTP`, which re-authorizes and pins the address on every
  attempt and never follows a redirect. Do not post callbacks with httpc/Req.

## Verification

From the umbrella root: `mix test apps/lemon_gateway/test`.
Tests stopping runtime applications restore exactly the original running set
with `Application.ensure_all_started/1`. Gateway transport tests may own gateway/
channels but must not stop unrelated consumers such as the control plane.
Exercise authenticated ingress, replay-store failure and unknown-outcome
handling, not just happy-path submission.
