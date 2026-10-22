# Backend changelog

## [Unreleased]

### Added

- `lemon-bot` now starts with no environment on the same machine as Lemon. It listens on `http://127.0.0.1:4100` (the old `4080` default collided with Lemon Web), keeps state in `~/.lemon/lemon_bot`, and finds the local controller the way the Lemon launchers do: `LEMON_CONTROL_PLANE_PORT`, then `~/.lemon/ports.env`, then 4040, authenticating with the launcher-managed `~/.lemon/run/control-plane-<port>.token`. That credential is re-read before every connection attempt, so the backend waits for a stopped Lemon and connects when it starts. An installed `~/.lemon/bin/lemon` becomes the default runtime launcher, so owners can choose **Start** in the app. Explicit `LEMON_BOT_*` settings still win; a same-machine credential is never sent to an off-machine controller.
- On first start in a terminal, `lemon-bot` asks whether to use the Lemon on this machine or another machine's. For this machine it reports whether Lemon is running and offers to start it (finishing Lemon's own setup first when needed). For another machine it takes the `wss://…/ws` controller address and a hidden operator token, verifies the connection and saves the choice in `DATA_DIR/controller.json` with the token encrypted by the product master key. `lemon-bot --choose-lemon` asks again. Until the owner workspace exists, an interactive start shows the one-use owner setup code on the controlling terminal only (never in stdout/stderr logs) and opens the web app in the browser; `--no-open` skips the browser. `bun run start` now runs the same CLI as `lemon-bot`, so source starts accept these flags.
- Added provider-free owner bootstrap with explicit local `lemon-bot setup`: verifies the existing instance's exact tailnet HTTPS origin, prints only the non-secret origin to stdout and shows the sensitive single-use setup proof only on the controlling terminal. Removed unconditional startup-log setup-code output. Proofs now have a five-minute absolute expiry and persisted ten-attempt fence, atomic race/consume protection and explicit local renewal; existing configured accounts/workspaces and pairing stay unchanged. `setup --print-origin` offers read-only verified-origin discovery without issuing a proof.
- Added terminal-only `lemon connect iphone` / `lemon-bot connect iphone` for an already-running Bot backend: hidden owner account login, shared HTTPS identity/workspace preflight, sensitive one-use paste link, exact device/code approval or denial, read-only uncertain-decision reconciliation and actual phone completion verification. No operator credential, backend launch or automatic approval is used.
- Phone-pairing CLI cleanup revokes only its temporary product session, preserving unrelated owner logins and optional OIDC provider sessions even on denial or failed preflight.
- Added a durable Bot backend identity, minimal public `/v1/setup` product/pairing descriptor and authenticated `/v1/identity` workspace binding. Shared origin preflight refuses wrong services, physical-phone loopback, identity/workspace mismatch, redirects and TLS bypass. Pairing QR links now require `backend/instance/cluster/code`; existing nonce, consent, expiry and revocation semantics remain intact.
- Added owner-only target-bound model-provider capability/status listing, write-only API-key add/replace and local disconnect on the execution machine, and a separate explicit default-model action. Product sessions/origin checks and current actual host ownership apply to initial requests and nonce replay; credentials never enter product storage or receipts.
- Added owner/session/target-bound Codex (`openai_codex`, the canonical runtime provider ID) device-login start, poll and cancel for the controller and actual owned execution nodes. Fixed nonces reconcile fresh target-only lifecycle state, including `lost` after runtime restart; only the exact provider verification URL, bounded code and status metadata reach clients. Current bearer/device authority, trusted origin, capabilities and ownership are checked around dispatch; product SQLite retains only safe admission receipts, never device grants or tokens.
- Added tolerant build/provider/channel instance health and owner-confirmed remote controller restart/stop, observing reconnect/disconnect completion with a 300-second deadline. Replaced the runtime-control boolean with explicit actions and launcher/controller routing.

### Fixed

- Codex OAuth success no longer persists credentials autonomously. Each normal
  poll first obtains an internal target challenge, then rechecks exact current
  owner/session/device/policy/target authority and durable revocation generation
  in a synchronous transaction before authorizing that exact nonce once. Its
  five-second deadline uses only the target's monotonic clock, including the
  serialized persistence check; product/controller wall-clock skew cannot extend
  authorization. Challenges remain memory-only and target restart invalidates
  them. Revocation advances durable authority generation immediately, even with
  the controller or target offline; no reservation blocks it. Durable login
  bindings stay revoked after authority is restored or a target is re-paired.
  Already-issued authorization has a bounded five-second write-admission window;
  an admitted persistence transaction may finish afterward. Unknown fixed
  completion IDs survive restart as settlement-only records without challenges,
  reconciling the same binding/ID without writing. Generic rejection never clears
  uncertainty; only exact acknowledgement or scoped definitive
  `provider_binding_rejected` evidence releases the journal. Public eight-field
  results remain unchanged; coverage uses mock OAuth/transport through the real
  Lemon adapter.

- Fixed Apple clients reporting a retired foreground-presence socket's error after a reconnect during an acknowledged message send. Current socket failures and uncertain message nonce fencing remain intact.
- Added owner-scoped read-only message receipts that retain the full original group target set and current run outcomes. Native clients automatically reconcile lost/late relay acknowledgements without resending, preserve refused/unknown targets, and acknowledge only the cursor delivered by each realtime frame.

## [0.1.0]

- Added the separate Bun/SQLite product API and static web serving, durable local account/member/device authorization, encrypted private credentials and exact nonce receipts.
- Added durable owner-only realtime replay, scoped deletion events and atomic sync snapshots.
- Added durable placed bot/profile lifecycles, reviewed templates, selected-resource copies, acknowledged move/reset/delete scopes and read-only uncertainty reconciliation.
- Added actual remote controller/node execution, fixed submission identities, truthful queued/steer/interrupt/cancel outcomes, enrollment compatibility checks, policy-rooted files and opener-bound real PTYs.
- Added invocation-authenticated product MCP tools, distinct owned-Bot group routing and known-refusal receipts, inherited handoffs, targeted gates/drafts and human-source preference checks.
- Added immutable validated attachments, authorization-bound range download tickets, actual artifact provenance and private persistent voice-session lifecycles.
- Added managed skills, profile-placed cron/webhook/event routines with authenticated creator admission, scoped memory/search, real usage/audit/policy/notification resources, reviewed memory import, activity/upcoming/ideas, conflict-safe preference undo and verified milestones.
- Added read-only Owner account-teardown status recovery after session revocation, completing reachable product cleanup independently from unconfirmed provider effects.
- Preserved exact 64-bit event cursors through SQLite decimal-text projections and added an adjacent-sequence regression above JavaScript's safe-integer limit.
- Closed the native tool inventory using the source-owned MCP alias projection; synchronized credential-free profile ceilings without owner credential lending and separated private execution results from bounded management status.
- Completed exact gate-resource lifecycle previews/cancellation, corrected typed resource pagination/atomic cron receipts, and supplied named HTTP/connector dependency contracts for deterministic provider fixtures.
- Preserved sealed native tool blocks during administrator hardening; made lifecycle fixtures honor complete measured presence and captured native aliases, and restored intentional outbox faults before teardown without suppressing failed transactions.
- Kept replay ordering on SQLite's integer source sequence while projecting decimal text, preserving streaming offsets across 9→10 and larger digit-width boundaries without precision loss.
- Awaited integration disposal before closing runtime/PTY transport and SQLite, allowing owned host operations to settle without late writes into a closed database.
- Cut all live Bot/chat/routine/channel/helper access over to actual ownership, removing Team publication, managers, other-human group membership, connector lending and the second SQLite memory store. Default personas describe the owner's personal assistant rather than a Team role.
- Added five-minute one-use QR preview/claim, desktop verification approval, fixed-nonce private completion recovery and persistent installation-bound revocable phone sessions. Safe pairing state events are restricted to current owner desktop devices.

Bot execution requires the coordinated platform RPCs, a supported controller default model and destination-local provider credentials with available quota; owner setup and management do not require a model/provider. See README.md and the canonical contracts.
