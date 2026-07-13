# Werewolf Production Readiness Goal

Status: complete

Owner: codex

Reviewer: codex

Last reviewed: 2026-07-10

## Goal

Make Lemon's Werewolf product production-ready as both a watchable model arena
and a configurable hosted game: cohesive responsive and accessible UX,
correct and recoverable gameplay, explicit runtime and game configuration,
secure player/host access, durable persistence, actionable observability,
reproducible packages, documented deployment and rollback, and realistic
multiplayer end-to-end proof.

Frontend design must remain code-native and must not use frontend-design
skills. Image generation may be used for original raster assets when it
materially improves the experience.

## Product Boundary

The product supports both AI simulation with an omniscient public broadcast and
hosted human multiplayer. They intentionally use separate information surfaces:

- an omniscient broadcast that may reveal hidden actions and private strategy;
- authenticated player views projected from server-owned state so no player can
  receive roles, journals, wolf chat, meetings, or night results they should not
  know.

The existing full-world `WerewolfBoard` must never be reused as a player view.

## Required Outcomes

### Game correctness

- Every phase transition, role action, runoff/tie, item, event, last-words path,
  and both win conditions are deterministic under a recorded seed and covered
  by lifecycle tests.
- Network-originated actions are authenticated, phase-valid, actor-valid,
  bounded, idempotent, and rejected before they enter authoritative history.
- Game snapshots retain rule configuration, model/player assignments, seed,
  command sequence, status, and recovery metadata.

### Broadcast UX

- A viewer can understand day/night phase, active speaker, living roster,
  claims, accusations, vote threshold and momentum, wolf parity pressure,
  hidden-action reveals, and the final result without reading raw telemetry.
- The page uses one natural document scroll, works at 375px through large
  displays, supports keyboard and screen-reader navigation, respects reduced
  motion, and does not force-scroll viewers away from history.
- Omniscient information is labeled explicitly. Usage and diagnostic data live
  in collapsed run details rather than interrupting the story.

### Host and player UX

- A host can create a room, choose rules and visibility, configure human/AI
  seats, share a join code, control timers, pause/resume/stop, replace a
  disconnected seat, export a replay, and start a rematch.
- Players can join, claim a seat, reconnect securely, see a private role-safe
  view, submit only legal actions, understand deadlines, and continue as a dead
  spectator without receiving forbidden information.
- Host, player, admin API, and public broadcast access policies are distinct and
  fail closed in production.

### Operations and packaging

- Browser assets are local, version-locked, compiled, and included in release
  and container artifacts with no runtime CDN dependency.
- The dedicated `sim_broadcast_platform` release and container validate
  required environment, persist state and league data, expose liveness and
  readiness endpoints, run as a non-root user, and shut down cleanly.
- Deployment is explicitly single-node while SQLite and local PubSub are in
  use. Backup, restore, migration, deploy, verification, and rollback commands
  are documented and exercised.
- Metrics cover game starts/completions/failures, phase duration, provider
  latency/errors, reconnects, rejected commands, persistence failures, and
  arena availability without exposing secrets or private game data.

### Verification

- Unit and integration suites cover rules, privacy, persistence, recovery,
  configuration, health, UI semantics, and release boot.
- Browser tests cover host plus multiple players, reconnect, timeout/default
  action, game completion, replay, 375x812, 768x1024, and 1440x900 viewports,
  keyboard use, and reduced motion.
- A deterministic keyless release/container smoke test proves public routes,
  admin denial, a stored Werewolf watch page, restart persistence, and
  readiness.
- Checked-in deterministic proof scenarios cover a complete multiplayer match,
  AI/model assignment and replay behavior, and failure/recovery cases.

## Delivery Sequence

1. Correctness, secure production defaults, local assets, durable paths,
   readiness, and package smoke tests.
2. Broadcast-first responsive redesign and accessibility pass.
3. Versioned game configuration, authoritative command validation, event
   durability, and deterministic recovery.
4. Hosted room lifecycle, role-safe player projection, authenticated commands,
   timers, reconnection, and host controls.
5. Replay route, observability, backups/restore/rollback, browser multiplayer
   QA, live multi-model proof, and final requirement-by-requirement audit.

## Current Evidence

Completed:

- audited game, UI, packaging, configuration, persistence, access, and tests;
- removed runtime CDN dependencies through version-locked local asset builds;
- added `/readyz`, container health checks, persistent Fly store paths,
  production environment validation, and a non-root container entrypoint;
- fixed saved-attack visibility, village-event discussion limits, dawn/evidence
  indexing, item-save kill accounting, transcript attribution, and cumulative
  usage/recovery accounting;
- rebuilt the responsive model broadcast and hosted lobby, join, role-blind
  host, private player, and public-safe story surfaces with local assets,
  accessible live announcements, reduced-motion support, and display-name
  presentation;
- added versioned story/classic rules, server-built legal commands, role-safe
  player/public projections, match/state epochs, idempotency namespaces,
  persisted RNG/deadlines, timeout defaults, pause/replacement, reconnect,
  stop/cancel, replay verification, rematch archives, and crash recovery;
- added hashed 256-bit credentials, sealed lobby roles, no-store private
  responses, lifetime-private rooms, HTTPS production enforcement, creation
  invites, bounded persistent sessions, a real kill switch, serialized pruning,
  active-room/retention/TTL caps, bounded AI concurrency, and frozen/validated
  per-room AI model configuration;
- made projection privacy default-deny for unknown events, moved raw LiveView
  credentials out of assigns and lifecycle logs, added final role reveals,
  waiting-only lobby projections, and distinct safe runtime-failure states;
- made persisted deadlines authoritative against late human/AI mailbox races and
  isolated provider randomness from updater RNG with full-game replay
  verification coverage;
- added protected sanitized metrics and readiness coverage for recovery,
  terminal persistence, provider work, actions, timeouts, reconnects, phase
  duration, room counts, and arenas;
- passed focused engine/room/LiveView/access suites and a five-browser hosted
  E2E covering secret non-leakage, real timeout, pause/resume, reconnect, full
  completion, replay download, rematch, keyboard/reduced-motion behavior, and
  375x812, 768x1024, and 1440x900 layouts;
- rebuilt and booted the production image with hosted mode enabled, verified
  secure/no-store cookies, protected metrics, UID 10001 execution, healthy
  readiness, immutable gzipped assets, and paused-room SQLite recovery after a
  container restart; the same hosted production restart proof is now in the
  release-smoke workflow;
- passed `645` LemonSim tests, `179` LemonSimUi tests, a forced
  warnings-as-errors compile, the final five-session browser smoke, zero-high
  npm audit, and independent backend, privacy/UX, and production audits with no
  unresolved blockers.

The production-readiness goal is complete. Deployment remains intentionally
single-node until room ownership, storage, and PubSub become distributed.
