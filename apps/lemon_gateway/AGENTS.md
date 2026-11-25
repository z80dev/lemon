# LemonGateway contributor guide

Gateway owns execution slots, launch isolation, native run lifecycle, cancellation
and resume. Router owns collect/follow-up/steer/interrupt semantics. Channels owns
messaging adapters; gateway-native SMS/voice/webhook ingress remains opt-in through
`:gateway_ingress_enabled`. See [README](README.md).

## Executor and lifecycle

- Gateway has one configured singleton executor, `CodingAgent.Executor`, validated
  by `LemonGateway.Executor`. Native runs carry fixed `engine: "lemon"` provenance;
  subagent identity never selects or replaces gateway execution.
- Do not restore engine registries, selectable/custom engines, vendor CLI runners
  or engine-selection config. Add model providers in `lemon_ai`, native tools in
  `coding_agent`, and delegation through the existing `task`/`agent` tools.
- The public submission boundary is
  `LemonGateway.Runtime.submit_execution(%LemonCore.ExecutionCommand{})`.
  Gateway constructs its private `ExecutionRequest`; consumers do not.
- `Runtime` starts `Run` directly; `Slots` is the sole global permit authority,
  with live Runs as FIFO waiters. Router `SessionCoordinator` alone orders conversations.
- Claim the engine session through `EngineSessionClaim` before requesting a
  permit. Contention is `:session_in_use`, not a wait while holding capacity.
- Check the durable terminal fence before admission and recheck terminal/cancel
  state after grant. Release permits and claims idempotently; owner death cleans up.
- Completion persists its receipt before notifying observers. Cancel by exact
  run ID, including waiting Runs; top-level resume accepts native tokens only.
- Direct execution callers bypass router backlog/process limits. See the
  [admission inventory](../../docs/architecture/admission-gates.md) for bounds.

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

## Operations

For stuck execution, inspect Slots counters, live Run children and router
conversation backlogs. For an unready executor, call
`LemonGateway.Executor.validate_configured/0`, not an engine registry lookup.
Resume state lives in `LemonCore.ChatStateStore` and the native session.

```elixir
LemonGateway.Slots.stats()
DynamicSupervisor.which_children(LemonGateway.RunSupervisor)
```

Bus events use `run:<run_id>`. `meta.notify_pid` may receive
`{:lemon_gateway_run_completed, request, completed}`. Keep these runtime contracts
separate from user-facing channel rendering.

## Verification

From the umbrella root: `mix test apps/lemon_gateway/test`.
Tests stopping runtime applications use `LemonPlatformTest.AppRestart` to restore
the original running set and env. Stop only apps the test owns, not unrelated
consumers such as the control plane.
Exercise FIFO admission, owner death, cancellation races, restart and replay-store
failure, not just happy-path submission.
