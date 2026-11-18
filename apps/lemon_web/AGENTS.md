# LemonWeb contributor guide

The assistant's Phoenix LiveView app is an operator client of the control plane:
LiveViews call `LemonControlPlane.Methods.Registry` in-process through
`LemonWeb.Rpc` and project Bus events with `LemonControlPlane.EventBridge.project/1`,
so they see the same schemas, scopes and bounded payloads as the TUI. Where a page
uses a lifecycle service directly it is the same shared service, never a Web-only
router, store or settings implementation. See [README](README.md) and
[user guide](../../docs/user-guide/web.md).

## Chat lifecycle

- `/` creates an isolated tab session; `/sessions/:session_key` resumes a validated
  key. Derive agent identity from that key, not an independent client claim.
- Subscribe only on connected mount. Scope session events and approvals to the
  session key. Preserve streaming/final dedupe so completion does not append the
  same answer twice. Transcript streams are bounded.
- Setup readiness fails closed before uploads are consumed, messages appended or
  router calls made. Setup mutations belong to shared CLI/provider services.
- Private chat resume may use `SessionLifecycle.history(..., redact: false)` only
  in-process. Management inspection, download and JSON-RPC history stay redacted.
- Reconcile active run on mount and before active controls. Only exact `:none`
  means idle; errors/unexpected responses are unavailable. A later lookup failure
  preserves known running/stopping state and the draft rather than falsely idle.
- Follow-up/steer/redirect use existing queue modes. Bounded guidance is text-only.
  Successful guidance keeps the original active run as stop target, not the newly
  returned submission ID. Refusal preserves drafts and exposes fixed safe text.
- Uploads retain configured count/size limits; do not submit while uploading.
  Display filenames, not managed filesystem paths. Keep readiness checks before
  consuming upload entries.

## Authentication

- Every route except `/login` and `/healthz` requires operator access, checked by
  `LemonWeb.Plugs.RequireOperator` per request and `LemonWeb.LiveAuth` on every
  LiveView mount (including the connected mount). There is no optional pipeline.
- The only credential is the control-plane operator token
  (`Authorize.configured_operator_token/0`). Login posts it from a form and
  delegates the comparison to `Authorize.from_params/2`; non-operator session
  tokens are refused. The session stores only a marker derived from the configured
  token, so rotation logs every browser out. Never accept tokens in query strings
  or headers for browser routes; `/login#token=` is read client-side only.
- No configured token fails closed (503) unless tokenless loopback compatibility
  is explicitly enabled and the actual socket peer (`conn.remote_ip` / LiveView
  `peer_data`) is loopback. Never consult forwarded headers. Failed logins are
  throttled per peer.
- `LemonWeb.RequestGuard` refuses a foreign `Host` from loopback peers (421)
  before any plug or the `/live` upgrade, and is the socket's fixed
  `check_origin` (exact origins from `config :lemon_web, :trusted_origins`).
  Never set `check_origin: false`, a code reloader or debug errors on the
  endpoint: `bin/lemon` serves it from the dev config.
- Cookie signing/encryption and LiveView tokens use the per-install secret key
  base (`config/runtime.exs` derives the LiveView salt from it); never commit one.
  Avoid putting credentials, private paths or raw service failures into assigns,
  logs or HTML.

## Management boundaries

- Sessions use `SessionLifecycle` for bounded/redacted list/history/export and
  lifecycle changes. Prune previews default archived-only/unpinned, show exact
  candidate keys, keep confirmation server-side and invalidate on mutations.
- Provider settings use `LemonAgent.ModelRuntime.ProviderConfiguration`. Preview
  precedes every write; apply checks a server-held revision, destructive actions
  require exact confirmation. Credentials use password fields and filtered logs;
  never retain secret values in socket drafts. Re-entry hashes bind preview.
- Profiles use the `profiles.*` methods through `LemonWeb.Rpc` (never
  `ProfileStore` directly, so writes reload the router cache) and sanitize before
  assignment. IDs, names, model/
  node/status/availability and canonical keys are allowed; paths/system prompts
  are not. Clone/rename/delete recheck opaque revision; delete also confirms exact
  ID and inherits trash-first rollback. Refused/stale writes keep safe drafts.
- Memory uses `LemonMemory.Lifecycle`: only bounded Safety-redacted summaries,
  allowlisted provenance, counts and digests. No raw URLs/workspace keys/paths,
  provider details, secret names or store errors. Delete previews bind exact
  document ID and every persisted-field revision; transactional stale refusal
  mutates neither document nor FTS row.
- Blueprints use `LemonAutomation.Blueprint.Catalog`; Web never reads manifests,
  copies skills, resolves paths or writes cron stores. State admits bounded IDs,
  counts, parsed schedule/action fields, audit enums and digest, not free-form
  names, prompts, skill bodies, commands, env values or paths. Activation requires
  retyping the fresh exact digest; drift clears preview, replay stays unchanged.
- All service projections are allowlists, not raw maps with a few keys removed.
  Redaction is additional defense, not a substitute for narrow projections.

## Verification

From the umbrella root: `mix test apps/lemon_web/test`.
Use connected LiveView tests for bus events, `file_input`/`render_upload` for
uploads and explicit session routes for stable keys. Verify initial and live
unavailable states, stale preview refusal, private-chat versus management
redaction, query-token redirect and required auth without credentials.
For UI changes, exercise actual browser interaction and responsive rendering;
static disconnected HTML alone cannot prove subscriptions or upload behavior.
