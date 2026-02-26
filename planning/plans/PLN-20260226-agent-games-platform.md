---
id: PLN-20260226-agent-games-platform
title: Agent-vs-Agent Game Platform (REST API + Live Spectator Web)
owner: codex
reviewer: codex
status: planned
workspace: 3191/lemon
change_id: pending
created: 2026-02-26
updated: 2026-02-26
---

## Goal

Build a reusable game platform where external agents can play turn-based games against a Lemon bot (and later other agents), while humans can watch matches live in the Lemon web UI.

## Product Outcome

1. Any agent owner can register credentials, create or accept challenges, and submit legal moves over HTTP.
2. Spectators can open a public match page and watch state updates live without refreshing.
3. The platform can add new game types without reworking transport, auth, or match lifecycle.

## Key Decisions

### Transport

1. **Agent control path**: REST over HTTP (`create_match`, `get_state`, `submit_move`, `poll_events`).
2. **Live viewing path**: Phoenix LiveView sockets + `LemonCore.Bus` match/lobby event fanout.
3. **Reasoning**: turn-based agents do not need persistent sockets in MVP; viewers do benefit from push updates.

### Authority Model

1. Server-authoritative game state.
2. Clients submit intents (moves), never full state.
3. Every accepted move is appended to an immutable event log and then projected to current state.

### Launch Scope

1. Ship MVP with `rock_paper_scissors` and `connect4`.
2. Defer chess/battleship until hidden-information redaction and time-control policies are proven.
3. MVP player mode is `external_agent` vs `lemon_bot` only.
4. Ranked ladders are out of MVP; launch with casual matches only.

### Product Policy Defaults (Locked 2026-02-26)

1. **Visibility default**: `public` by default, with explicit `private`/`unlisted` options at match creation.
2. **MVP pairing**: no external-agent-vs-external-agent in MVP; add in phase 2 after operations hardening.
3. **Token issuance**: canonical first surface is control-plane RPC/API (with CLI wrapper), web UI token management follows.
4. **Ranking**: disabled in MVP; only casual and replayable matches.

## Scope

### In Scope (MVP)

1. New umbrella app: `apps/lemon_games/`.
2. Public HTTP API for agent play.
3. Live spectator UI in `apps/lemon_web`.
4. Lemon bot strategy workers for initial games.
5. One first-party skill for external agents to integrate quickly.
6. Metrics, rate limits, turn deadlines, idempotent move submission.

### Out of Scope (MVP)

1. Paid tournaments, betting, on-chain settlement.
2. Real-time clocks/blitz chess.
3. Simultaneous-action hidden commit/reveal protocols (except basic RPS handling).
4. Fully open anonymous play without auth.

## Architecture

### App and Module Plan

### New app: `apps/lemon_games`

1. `LemonGames.Application`
   - Supervises match service, projections, and pubsub bridge workers.
2. `LemonGames.Games.Game` behaviour
   - `init/1`
   - `public_state/2`
   - `legal_moves/2`
   - `apply_move/3`
   - `winner/1`
   - `terminal_reason/1`
3. `LemonGames.Games.RockPaperScissors`
4. `LemonGames.Games.Connect4`
5. `LemonGames.Matches.Match` struct + state machine helpers.
6. `LemonGames.Matches.Service`
   - Match create/accept/forfeit/submit_move.
7. `LemonGames.Matches.EventLog`
   - Append/read events with optimistic sequence control.
8. `LemonGames.Matches.Projection`
   - Rebuild or incrementally update latest state from events.
9. `LemonGames.Auth`
   - API token verification, owner scoping.
10. `LemonGames.RateLimit`
    - Per-key request and per-match move burst guards.

### Integrations

1. `apps/lemon_control_plane`
   - Add public REST endpoints under `/v1/games/*`.
   - Add OpenAPI/endpoint docs.
2. `apps/lemon_web`
   - Lobby page (`/games`) and match page (`/games/:id`).
   - WebSocket subscriptions for lobby and match streams.
3. `apps/lemon_core`
   - Persistent storage primitives for matches and events (SQLite-backed where applicable).
4. `apps/lemon_skills`
   - Skill doc + helper flow for agent onboarding.

## Data Model

### `game_matches`

1. `id` (ULID/UUID)
2. `game_type` (`rock_paper_scissors` | `connect4` | future)
3. `status` (`pending_accept`, `active`, `finished`, `expired`, `aborted`)
4. `ruleset_version`
5. `created_by`
6. `next_player`
7. `turn_number`
8. `result` (winner/draw/termination reason)
9. `inserted_at`, `updated_at`

### `game_match_players`

1. `match_id`
2. `slot` (`p1`, `p2`)
3. `agent_id`
4. `display_name`
5. `agent_type` (`lemon_bot`, `external_agent`)

### `game_match_events`

1. `match_id`
2. `seq` (strictly increasing)
3. `event_type` (`match_created`, `accepted`, `move_submitted`, `move_rejected`, `turn_advanced`, `finished`, ...)
4. `actor`
5. `payload` (JSON)
6. `idempotency_key` (optional)
7. `inserted_at`

## API Contract (MVP)

### Auth

1. `Authorization: Bearer <agent_token>`
2. Optional hardening phase: signed timestamp headers to prevent replay.

### Endpoints

1. `POST /v1/games/matches`
   - Create challenge (`game_type`, opponent type, optional rule options).
2. `POST /v1/games/matches/:id/accept`
3. `GET /v1/games/matches/:id`
   - Returns redacted state for caller.
4. `POST /v1/games/matches/:id/moves`
   - Requires `idempotency_key`.
5. `GET /v1/games/matches/:id/events?after_seq=N`
   - Poll-based event feed for agents.
6. `GET /v1/games/lobby`
   - Public list of live and recent finished games.
7. `games.token.*` (control-plane JSON-RPC methods)
   - Admin token issue/list/revoke for external agent access.

### Live Update Transport (MVP)

1. No dedicated `WS /v1/games/ws` endpoint in MVP.
2. Spectator live updates are delivered through Phoenix LiveView sockets in `lemon_web` using `LemonCore.Bus` subscriptions.
3. Phase-2 option: add a standalone control-plane games websocket endpoint for non-browser consumers.

### Error model

1. `400` invalid payload.
2. `401/403` auth or ownership violation.
3. `404` match not visible.
4. `409` invalid turn, stale move, duplicate idempotency key.
5. `422` illegal move (game-rules rejection).

## Match Lifecycle

1. `pending_accept` -> `active` -> `finished`
2. Side paths: `expired` (accept/turn timeout), `aborted` (admin/system action)
3. Deadlines:
   - Acceptance timeout (default 5 min)
   - Per-turn timeout (default 30s for RPS, 60s for Connect4)
4. Timeout action policy:
   - First timeout: warning + auto-pass if game supports it.
   - Repeated timeout or unsupported-pass game: forfeit loss.

## Live Web Experience

1. `/games`
   - Active matches, recently finished, watch links.
2. `/games/:id`
   - Board render + move timeline + current turn + result banner.
3. Push model:
   - Control plane / game service emits events via PubSub.
   - Web layer subscribes and patches LiveView state incrementally.
4. Replay:
   - Match page can rebuild board from event sequence for deterministic playback.

## Skill Contract for External Agents

1. Create skill doc under Lemon skill registry with:
   - auth setup
   - match create/join flow
   - turn loop (`poll -> decide -> submit_move`)
2. Provide language-agnostic request examples (curl + JSON).
3. Include strict idempotency and retry guidance.
4. Add starter templates for common game loops (RPS and Connect4).

## Implementation Milestones

### M0 - RFC + API Freeze (2-3 days)

1. Finalize endpoint payload schemas.
2. Lock event types and redaction model.
3. Publish docs stub and example flows.

**Exit criteria**
1. API schema reviewed and frozen for MVP.
2. Basic threat model documented (auth, replay, abuse).

### M1 - Core Domain Engine (4-6 days)

1. Create `lemon_games` app skeleton.
2. Implement game behaviour, match state machine, event append path.
3. Implement RPS and Connect4 engines with property/unit tests.

**Exit criteria**
1. `apply_move` deterministic under repeated replay.
2. 100% legal/illegal move coverage for both MVP games.

### M2 - Storage + Projections (3-4 days)

1. Persist match/event records through `lemon_core` storage layer.
2. Add snapshot/projection mechanism for fast `GET /state`.
3. Add sequence-consistency checks and idempotency dedupe.

**Exit criteria**
1. Recovery test: rebuild state from events after restart.
2. No duplicate move commits under client retries.

### M3 - Public API Surface (4-5 days)

1. Add REST endpoints in control plane.
2. Add auth middleware and ownership checks.
3. Add control-plane `games.token.*` RPC methods for admin token management.
4. Emit match/lobby events to `LemonCore.Bus` for live web pages.

**Exit criteria**
1. End-to-end API tests pass for create, accept, move, and observe.
2. Unauthorized and illegal transitions are rejected correctly.

### M4 - Lemon Bot Players (3-5 days)

1. Add Lemon bot strategy modules:
   - RPS weighted random.
   - Connect4 heuristic (win/block/center preference).
2. Add match worker loop for bot turns.

**Exit criteria**
1. Bot completes full matches with no deadlocks.
2. Move latency p95 under target on local bench.

### M5 - Web Spectator MVP (4-6 days)

1. Add lobby and match pages in `lemon_web`.
2. Render boards from normalized game-state view models.
3. Subscribe to `LemonCore.Bus` topics for near-live animation/timeline.

**Exit criteria**
1. Spectator page updates live during active game.
2. Page reload restores exact current state from API.

### M6 - External Skill + Docs (2-3 days)

1. Add skill documentation and integration examples.
2. Add docs for API, auth, limits, and game rules.
3. Update relevant `AGENTS.md`/README docs for new app boundaries.

**Exit criteria**
1. A clean-room external agent can finish a full Connect4 game using docs only.

### M7 - Hardening + Rollout (3-4 days)

1. Rate limiting, abuse controls, and telemetry dashboards.
2. Feature flags for game type enablement.
3. Staged rollout:
   - Internal only
   - Allowlisted agent tokens
   - Public beta

**Exit criteria**
1. No critical errors in staged beta over 100+ matches.
2. Operational runbook prepared.

## Testing Strategy

1. Unit tests:
   - Per-game legal move validation and winner detection.
2. Property tests:
   - Event replay determinism.
   - Turn-order invariants.
3. Integration tests:
   - REST + WS + persistence happy path and failure modes.
4. UI tests:
   - LiveView match page updates and replay correctness.
5. Load tests:
   - 500 concurrent active matches target for MVP benchmark.

## Security and Abuse Controls

1. Token scopes: `games:read`, `games:play`, `games:admin`.
2. Idempotency key required for `submit_move`.
3. Rate limits:
   - per-token req/min
   - per-match move submit burst
4. Replay defense:
   - timestamp tolerance + nonce cache (phase 2 hardening).
5. Moderation controls:
   - hide private matches from public lobby.
   - owner controls for visibility.

## Observability

1. Metrics:
   - match creations, active matches, move latency, illegal move rate, timeout rate.
2. Structured logs:
   - include `match_id`, `game_type`, `agent_id`, `seq`.
3. Tracing:
   - endpoint -> domain service -> storage append -> ws broadcast.
4. Alerts:
   - elevated `409/422` spikes.
   - WS fanout lag.

## Rollout Plan

1. Phase A: Internal match generation only.
2. Phase B: Invite-only external agent keys.
3. Phase C: Public lobby and open watch links.
4. Phase D: Add external-agent-vs-external-agent pairing.
5. Phase E: Add ranked mode and additional games.

## Risks and Mitigations

1. **Risk**: API abuse or spam matches.
   - **Mitigation**: token quotas, per-owner match caps, cooldowns.
2. **Risk**: hidden-info leaks in future games.
   - **Mitigation**: strict `public_state/2` redaction contract and tests.
3. **Risk**: WS fanout overload.
   - **Mitigation**: bounded topics, backpressure, optional SSE fallback.
4. **Risk**: bot stalls causing dead games.
   - **Mitigation**: supervised turn workers with timeout failover.

## Success Criteria

- [ ] External agent can play full RPS match against Lemon bot via documented API.
- [ ] External agent can play full Connect4 match against Lemon bot via documented API.
- [ ] Public web user can watch active match state update live in browser.
- [ ] Match replay from stored events produces identical terminal state.
- [ ] Auth/rate-limit/idempotency protections pass adversarial integration tests.
- [ ] Documentation is complete across plan + app guides + API docs.

## Open Questions

No blocking open questions for MVP scope as of 2026-02-26.

## Implementation Handoff

For implementation-level instructions (file-by-file, function signatures, API payloads, and test plan), follow:

- `planning/plans/PLN-20260226-agent-games-platform-implementation-guide.md`

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-02-26 00:00 | codex | Drafted platform implementation plan | Planned | `planning/plans/PLN-20260226-agent-games-platform.md` |
| 2026-02-26 00:10 | codex | Added implementation-grade handoff guide for Opus 4.6 | Planned | `planning/plans/PLN-20260226-agent-games-platform-implementation-guide.md` |
