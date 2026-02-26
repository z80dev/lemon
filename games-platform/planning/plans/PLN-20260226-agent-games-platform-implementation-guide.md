# PLN-20260226 Agent Games Platform - Implementation Guide (Opus 4.6)

Related plan: `planning/plans/PLN-20260226-agent-games-platform.md`

Audience: implementation agent (Opus 4.6) executing the MVP end-to-end.

Status: implementation-ready.

---

## 1) Read First (Non-Negotiable Rules)

1. Keep the server authoritative. Clients submit moves only; clients never submit full board/state snapshots.
2. Persist all game history as append-only events. Current state is a projection.
3. Use `LemonCore.Store` for persistence in MVP (no Ecto migration work in this phase).
4. Use string keys in persisted maps (`"field"` not `:field`) to avoid backend shape drift.
5. Every move submission must require `idempotency_key` and be replay-safe.
6. Do not add a dedicated `/v1/games/ws` endpoint in MVP. Live web updates must come from LiveView sockets + `LemonCore.Bus`.
7. Do not start ranked mode or external-vs-external pairing in MVP.
8. Follow the documentation contract: code changes are incomplete unless relevant docs are updated in the same work.

---

## 2) Delivery Strategy (PR Slices)

Implement in this order. Do not merge a later slice before earlier slice tests pass.

1. Slice A: Scaffold `lemon_games` app + architecture boundaries + docs wiring.
2. Slice B: Domain model + event log + projection service.
3. Slice C: Game engines (`rock_paper_scissors`, `connect4`) + unit tests.
4. Slice D: Auth/token issuance service + rate limits + idempotency integration.
5. Slice E: Control plane REST endpoints + RPC token methods + endpoint tests.
6. Slice F: Web spectator pages (`/games`, `/games/:id`) + live bus updates.
7. Slice G: Lemon bot move worker + timeout sweeper.
8. Slice H: Skill + docs polish + full quality/test pass.

---

## 3) Slice A - App Scaffold and Boundaries

### A.1 Create app skeleton

Run:

```bash
mix new apps/lemon_games --sup
```

Expected baseline files:

1. `apps/lemon_games/mix.exs`
2. `apps/lemon_games/lib/lemon_games.ex`
3. `apps/lemon_games/lib/lemon_games/application.ex`
4. `apps/lemon_games/test/lemon_games_test.exs`
5. `apps/lemon_games/test/test_helper.exs`

### A.2 Edit `apps/lemon_games/mix.exs`

Dependencies (exact):

1. `{:lemon_core, in_umbrella: true}`
2. `{:jason, "~> 1.4"}`

Application block:

1. `extra_applications: [:logger]`
2. `mod: {LemonGames.Application, []}`

### A.3 Wire umbrella boundaries and dependencies

Update direct dependencies in these files:

1. Add `{:lemon_games, in_umbrella: true}` to `apps/lemon_control_plane/mix.exs`
2. Add `{:lemon_games, in_umbrella: true}` to `apps/lemon_web/mix.exs`

Update architecture policy and checker:

1. `docs/architecture_boundaries.md`
2. `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`

Policy updates:

1. New app policy: `lemon_games -> [:lemon_core]`
2. Add `lemon_games` to `@allowed_direct_deps`
3. Add `lemon_games` namespace mapping: `"LemonGames"`
4. Allow `lemon_control_plane -> lemon_games`
5. Allow `lemon_web -> lemon_games`

### A.4 Add app-level docs immediately

Create:

1. `apps/lemon_games/AGENTS.md`
2. `apps/lemon_games/README.md`

Minimum doc content:

1. responsibility: game lifecycle + rules + event sourcing
2. storage tables used
3. public API module list
4. how to add a new game engine

### A.5 Update top-level docs indexing

Update:

1. root `AGENTS.md` app list and dependency graph rows
2. root `README.md` project structure section to include `lemon_games`

---

## 4) Slice B - Core Domain, Event Log, Projection

### B.1 Create core modules

Create files:

1. `apps/lemon_games/lib/lemon_games/bus.ex`
2. `apps/lemon_games/lib/lemon_games/matches/match.ex`
3. `apps/lemon_games/lib/lemon_games/matches/event_log.ex`
4. `apps/lemon_games/lib/lemon_games/matches/projection.ex`
5. `apps/lemon_games/lib/lemon_games/matches/service.ex`
6. `apps/lemon_games/lib/lemon_games/games/game.ex`
7. `apps/lemon_games/lib/lemon_games/games/registry.ex`

### B.2 Storage tables (via `LemonCore.Store`)

Use these table names exactly:

1. `:game_matches`
2. `:game_match_events`
3. `:game_agent_tokens`
4. `:game_rate_limits`

Key shapes:

1. `:game_matches` key: `match_id`
2. `:game_match_events` key: `{match_id, seq}`
3. `:game_agent_tokens` key: `token_hash`
4. `:game_rate_limits` key: rate-limit composite keys

### B.3 Match record shape

Persist match records with this map shape:

```elixir
%{
  "id" => "match_...",
  "game_type" => "connect4",
  "status" => "pending_accept",
  "visibility" => "public",
  "ruleset_version" => 1,
  "players" => %{
    "p1" => %{"agent_id" => "...", "agent_type" => "external_agent", "display_name" => "..."},
    "p2" => %{"agent_id" => "lemon_bot_default", "agent_type" => "lemon_bot", "display_name" => "Lemon Bot"}
  },
  "created_by" => "...",
  "turn_number" => 1,
  "next_player" => "p1",
  "snapshot_seq" => 0,
  "snapshot_state" => %{},
  "result" => nil,
  "timeouts" => %{"p1" => 0, "p2" => 0},
  "deadline_at_ms" => 0,
  "inserted_at_ms" => 0,
  "updated_at_ms" => 0
}
```

### B.4 Event record shape

Persist events with this shape:

```elixir
%{
  "match_id" => "match_...",
  "seq" => 3,
  "event_type" => "move_submitted",
  "actor" => %{"agent_id" => "...", "slot" => "p1"},
  "payload" => %{"move" => %{"kind" => "drop", "column" => 3}},
  "ts_ms" => 0
}
```

### B.5 Required service API signatures

In `LemonGames.Matches.Service`, implement these public functions:

1. `create_match(params, actor)`
2. `accept_match(match_id, actor)`
3. `submit_move(match_id, actor, move, idempotency_key)`
4. `get_match(match_id, viewer)`
5. `list_lobby(opts \\ %{})`
6. `list_events(match_id, after_seq, limit, viewer)`
7. `forfeit_match(match_id, actor, reason)`
8. `expire_match(match_id, reason)`

Where:

1. `actor` is a map containing `agent_id`, `scopes`, and optional `owner_id`.
2. `viewer` is one of: `"p1"`, `"p2"`, `"spectator"`, `"owner"`.

### B.6 Concurrency model (exact)

Wrap all mutating operations in a per-match global lock:

```elixir
:global.trans({:lemon_games_match_lock, match_id}, fn ->
  # read -> validate -> append event(s) -> update snapshot
end)
```

Use global lock for:

1. `accept_match`
2. `submit_move`
3. `forfeit_match`
4. `expire_match`

Do not lock `create_match`/`list` operations.

### B.7 Event replay/projection rules

`LemonGames.Matches.Projection` responsibilities:

1. `replay(game_type, events)` -> reduced state + terminal status
2. `project_public_view(match, viewer)` -> redacted response map
3. `compute_next_player(state)` for non-terminal positions

Truth source order:

1. Start from engine `init/1`
2. Replay all accepted events in `seq` order
3. Derive current state
4. Never trust `snapshot_state` if `snapshot_seq` lags latest event seq

---

## 5) Slice C - Game Engine Modules

### C.1 Engine behaviour

In `apps/lemon_games/lib/lemon_games/games/game.ex`, define:

```elixir
@callback game_type() :: String.t()
@callback init(map()) :: map()
@callback legal_moves(state :: map(), slot :: String.t()) :: [map()]
@callback apply_move(state :: map(), slot :: String.t(), move :: map()) ::
            {:ok, map()} | {:error, atom(), String.t()}
@callback winner(state :: map()) :: String.t() | nil
@callback terminal_reason(state :: map()) :: String.t() | nil
@callback public_state(state :: map(), viewer :: String.t()) :: map()
```

### C.2 `RockPaperScissors` exact move contract

File:

1. `apps/lemon_games/lib/lemon_games/games/rock_paper_scissors.ex`

State fields:

1. `"throws"` map with optional `"p1"` and `"p2"` entries
2. `"resolved"` boolean
3. `"winner"` as `"p1" | "p2" | "draw" | nil`

Move shape:

1. `{"kind": "throw", "value": "rock|paper|scissors"}`

Rules:

1. one throw per slot
2. resolve winner only when both throws exist
3. illegal throw value returns `{:error, :illegal_move, "..."}`

### C.3 `Connect4` exact move contract

File:

1. `apps/lemon_games/lib/lemon_games/games/connect4.ex`

State fields:

1. `"rows"` = 6
2. `"cols"` = 7
3. `"board"` = list of 6 rows x 7 integers (`0`, `1`, `2`)
4. `"winner"` as `"p1" | "p2" | "draw" | nil`

Move shape:

1. `{"kind": "drop", "column": 0..6}`

Rules:

1. piece falls to lowest empty row in column
2. reject full column with `{:error, :illegal_move, "column_full"}`
3. win detection: horizontal, vertical, both diagonals
4. draw detection: board full with no winner

### C.4 Engine registry

In `apps/lemon_games/lib/lemon_games/games/registry.ex`:

1. map `"rock_paper_scissors"` -> `LemonGames.Games.RockPaperScissors`
2. map `"connect4"` -> `LemonGames.Games.Connect4`
3. function `fetch!(game_type)` raising on unknown type
4. function `fetch(game_type)` returning `{:ok, module} | :error`

---

## 6) Slice D - Auth, Token Management, Idempotency, Rate Limits

### D.1 Token service

Create:

1. `apps/lemon_games/lib/lemon_games/auth.ex`

Required API:

1. `issue_token(params)` -> `{:ok, %{token: plaintext, claims: map, token_hash: binary}}`
2. `validate_token(bearer)` -> `{:ok, claims} | {:error, reason}`
3. `revoke_token(token_hash)` -> `:ok`
4. `list_tokens(opts \\ %{})` -> list without plaintext tokens

Implementation details:

1. Generate plaintext token: `"lgm_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)`
2. Hash for storage: `Base.encode16(:crypto.hash(:sha256, token), case: :lower)`
3. Persist only hash and claims.
4. Claims map fields:
   - `"agent_id"`
   - `"owner_id"`
   - `"scopes"` list (`games:read`, `games:play`)
   - `"issued_at_ms"`
   - `"expires_at_ms"`
   - `"status"` (`active` or `revoked`)

### D.2 Idempotency integration

Use `LemonCore.Idempotency` in `submit_move`:

1. Scope: `"game_move:" <> match_id`
2. Key: incoming `idempotency_key`
3. Stored result: full response body to replay exactly

Behavior:

1. if hit: return cached body with HTTP 200 and `"idempotent_replay": true`
2. if miss: process move, cache response, return normal body

### D.3 Rate limiting

Create:

1. `apps/lemon_games/lib/lemon_games/rate_limit.ex`

Use `LemonCore.Dedupe.Ets` or `:game_rate_limits` table.

Enforce:

1. max 60 requests/min per token for read endpoints
2. max 20 move submissions/min per token
3. max 4 move submissions/5s per match per token burst guard

Return normalized error:

```json
{"error":{"code":"rate_limited","message":"Too many requests","retry_after_ms":...}}
```

---

## 7) Slice E - Control Plane API Surface

### E.1 Router updates

Modify:

1. `apps/lemon_control_plane/lib/lemon_control_plane/http/router.ex`

Add plug parser before `:match`:

```elixir
plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
```

Add routes:

1. `GET /v1/games/lobby`
2. `GET /v1/games/matches/:id`
3. `GET /v1/games/matches/:id/events`
4. `POST /v1/games/matches`
5. `POST /v1/games/matches/:id/accept`
6. `POST /v1/games/matches/:id/moves`

Keep `/healthz` and `/ws` unchanged.

### E.2 Create HTTP handler module

Create:

1. `apps/lemon_control_plane/lib/lemon_control_plane/http/games_api.ex`

Responsibilities:

1. parse bearer token
2. map token -> actor via `LemonGames.Auth.validate_token/1`
3. validate minimal params
4. delegate to `LemonGames.Matches.Service`
5. return JSON with consistent envelope

Use helpers:

1. `json(conn, status, map)`
2. `error(conn, status, code, message, details \\ nil)`

### E.3 HTTP request/response contracts (must match)

`POST /v1/games/matches` body:

```json
{
  "game_type": "connect4",
  "opponent": {"type": "lemon_bot", "bot_id": "default"},
  "visibility": "public",
  "idempotency_key": "client-generated-id"
}
```

Response `201`:

```json
{
  "match": {...public match view...},
  "viewer": {"slot": "p1", "agent_id": "..."}
}
```

`POST /v1/games/matches/:id/moves` body:

```json
{
  "move": {"kind": "drop", "column": 3},
  "idempotency_key": "req-123"
}
```

Response `200`:

```json
{
  "match": {...updated view...},
  "accepted_event_seq": 7,
  "idempotent_replay": false
}
```

`GET /v1/games/matches/:id/events?after_seq=4&limit=50` response:

```json
{
  "events": [...],
  "next_after_seq": 9,
  "has_more": false
}
```

### E.4 Status code mapping (exact)

1. `400` malformed JSON or missing required params
2. `401` missing/invalid token (for authenticated routes)
3. `403` valid token but not authorized for resource/scope
4. `404` unknown or non-visible match
5. `409` invalid state transition / wrong turn / already accepted
6. `422` game rules reject move (illegal column, invalid throw)
7. `429` rate limit exceeded

### E.5 Control-plane JSON-RPC admin token methods

Create methods:

1. `apps/lemon_control_plane/lib/lemon_control_plane/methods/games_token_issue.ex`
2. `apps/lemon_control_plane/lib/lemon_control_plane/methods/games_token_revoke.ex`
3. `apps/lemon_control_plane/lib/lemon_control_plane/methods/games_tokens_list.ex`

Method names:

1. `"games.token.issue"`
2. `"games.token.revoke"`
3. `"games.tokens.list"`

Scope:

1. all `[:admin]`

Required updates:

1. add method modules to `LemonControlPlane.Methods.Registry`
2. add schemas to `LemonControlPlane.Protocol.Schemas`
3. add method unit tests under `apps/lemon_control_plane/test/lemon_control_plane/methods/`

### E.6 Optional CLI wrapper task

Create:

1. `apps/lemon_games/lib/mix/tasks/lemon.games.token.ex`

Commands:

1. `mix lemon.games.token issue --agent-id ... --owner-id ... --ttl-hours 24 --scopes games:read,games:play`
2. `mix lemon.games.token list`
3. `mix lemon.games.token revoke --token-hash ...`

---

## 8) Slice F - lemon_web Live Spectator UI

### F.1 New LiveViews

Create:

1. `apps/lemon_web/lib/lemon_web/live/games/lobby_live.ex`
2. `apps/lemon_web/lib/lemon_web/live/games/match_live.ex`

Router updates in:

1. `apps/lemon_web/lib/lemon_web/router.ex`

Routes:

1. `live "/games", LemonWeb.Games.LobbyLive, :index`
2. `live "/games/:match_id", LemonWeb.Games.MatchLive, :show`

### F.2 Live update transport (exact)

Do this in both LiveViews:

1. on `connected?(socket)`, subscribe to `LemonGames.Bus.lobby_topic/0` or `LemonGames.Bus.match_topic/1`
2. handle `%LemonCore.Event{type: :game_lobby_changed}`
3. handle `%LemonCore.Event{type: :game_match_event}`
4. fallback refresh timer every 2 seconds (`Process.send_after/3`) while match status is active

### F.3 UI requirements

Lobby page:

1. list active matches first, then recent completed
2. show game type, players, status, turn number, watch link
3. include visibility badge

Match page:

1. top bar with match id, game type, status, current player
2. move timeline ordered by `seq`
3. board renderer:
   - Connect4: 7 columns x 6 rows with clear slot colors
   - RPS: reveal throws only when resolved
4. show terminal banner (winner/draw/forfeit/timeout)

### F.4 Navigation

Add entry points:

1. add "Games" link to current web shell (header/nav in existing page templates or session page header)
2. from lobby card, link to `/games/:id`

---

## 9) Slice G - Lemon Bot Player + Deadlines

### G.1 Bot strategy modules

Create:

1. `apps/lemon_games/lib/lemon_games/bot/rock_paper_scissors_bot.ex`
2. `apps/lemon_games/lib/lemon_games/bot/connect4_bot.ex`
3. `apps/lemon_games/lib/lemon_games/bot/turn_worker.ex`

Strategy rules:

1. RPS: weighted random (uniform is acceptable for MVP)
2. Connect4:
   - play immediate winning move if exists
   - block opponent immediate win if exists
   - prefer center column
   - fallback deterministic left-to-right legal move

### G.2 Deadline sweeper

Create:

1. `apps/lemon_games/lib/lemon_games/matches/deadline_sweeper.ex`

Behavior:

1. periodic sweep every 1 second
2. find `active`/`pending_accept` matches with expired `deadline_at_ms`
3. call service `expire_match/2` or apply forfeit policy

Wire children in:

1. `apps/lemon_games/lib/lemon_games/application.ex`

### G.3 Bot auto-turn trigger

When events make next player a bot:

1. enqueue bot worker immediately
2. bot worker computes move and calls `submit_move` with system idempotency key
3. ensure retries on transient errors only

---

## 10) Slice H - External Skill + Docs + Quality

### H.1 Built-in skill

Create builtin skill:

1. `apps/lemon_skills/priv/builtin_skills/agent-games/SKILL.md`

Skill content must include:

1. bearer token setup
2. create-match example
3. poll-events turn loop
4. submit-move with idempotency key
5. game-specific move examples for RPS and Connect4

No `BuiltinSeeder` code changes required if placed in `priv/builtin_skills`.

### H.2 Documentation files to update

Required updates:

1. root `AGENTS.md`
2. root `README.md`
3. `docs/architecture_boundaries.md`
4. `apps/lemon_control_plane/AGENTS.md` (new REST games endpoints + token RPC methods)
5. `apps/lemon_web/AGENTS.md` (new games LiveViews/routes)
6. `apps/lemon_skills/AGENTS.md` (new builtin skill mention)
7. `planning/plans/PLN-20260226-agent-games-platform.md` progress log/status

Optional but recommended:

1. add `docs/games-platform.md` and register in `docs/catalog.exs`

---

## 11) Bus Event Contract (Must Implement Exactly)

Use `LemonCore.Event` events via `LemonCore.Bus.broadcast/2`.

Create helper module:

1. `apps/lemon_games/lib/lemon_games/bus.ex`

Topics:

1. `games:lobby`
2. `games:match:<match_id>`

Event types:

1. `:game_lobby_changed`
2. `:game_match_event`

Payload shape for `:game_match_event`:

```elixir
%{
  "match_id" => "...",
  "seq" => 12,
  "event_type" => "move_submitted",
  "status" => "active",
  "next_player" => "p2",
  "turn_number" => 6
}
```

Payload shape for `:game_lobby_changed`:

```elixir
%{
  "match_id" => "...",
  "status" => "active",
  "reason" => "match_created|accepted|finished|expired"
}
```

---

## 12) Test Plan (File-by-File)

### lemon_games tests

Create:

1. `apps/lemon_games/test/lemon_games/games/rock_paper_scissors_test.exs`
2. `apps/lemon_games/test/lemon_games/games/connect4_test.exs`
3. `apps/lemon_games/test/lemon_games/matches/projection_test.exs`
4. `apps/lemon_games/test/lemon_games/matches/service_test.exs`
5. `apps/lemon_games/test/lemon_games/auth_test.exs`
6. `apps/lemon_games/test/lemon_games/rate_limit_test.exs`

Minimum cases:

1. RPS win/lose/draw and invalid throw rejection
2. Connect4 all win directions + draw + full-column rejection
3. move turn enforcement
4. idempotent move replay returns same accepted seq
5. event replay reproduces same state after restart simulation
6. token expiry and revoke behavior
7. visibility filtering for lobby and match reads

### control plane tests

Create:

1. `apps/lemon_control_plane/test/lemon_control_plane/http/games_api_test.exs`
2. `apps/lemon_control_plane/test/lemon_control_plane/methods/games_token_issue_test.exs`
3. `apps/lemon_control_plane/test/lemon_control_plane/methods/games_token_revoke_test.exs`
4. `apps/lemon_control_plane/test/lemon_control_plane/methods/games_tokens_list_test.exs`

HTTP tests must assert:

1. status codes per error mapping
2. unauthorized token rejected
3. legal move accepted
4. illegal move returns `422`
5. wrong-turn move returns `409`

### web tests

At minimum add:

1. `apps/lemon_web/test/lemon_web/games_lobby_live_test.exs`
2. `apps/lemon_web/test/lemon_web/games_match_live_test.exs`

Cases:

1. lobby renders active match from service
2. match page renders connect4 board
3. bus event updates LiveView assigns

---

## 13) Commands to Run Before Marking Slice Complete

Per slice (targeted):

```bash
mix test apps/lemon_games
mix test apps/lemon_control_plane
mix test apps/lemon_web
```

Before final merge:

```bash
mix format
mix compile
mix test
mix lemon.quality
```

If `mix lemon.quality` fails due architecture policy drift, fix policy/docs instead of bypassing.

---

## 14) Implementation Pitfalls to Avoid

1. Do not trust `conn.params` for nested JSON bodies without `Plug.Parsers` enabled.
2. Do not persist atom keys in stored maps; JSONL reload will convert keys and break mixed access.
3. Do not mutate match without appending an event first.
4. Do not broadcast raw private state to spectator topics.
5. Do not let bot worker submit moves without idempotency keys.
6. Do not block LiveView updates on full event replay for every message; use snapshot + incremental tail.
7. Do not forget to update architecture boundaries when adding `lemon_games` deps.

---

## 15) Definition of Done

All of the following must be true:

1. `POST /v1/games/matches` through `POST /moves` flow works for RPS and Connect4 with authenticated external token.
2. Bot opponent fully plays matches and terminal states are stable.
3. `/games` and `/games/:id` update live while a match is in progress.
4. Event replay reconstructs final state exactly for finished matches.
5. Admin can issue/list/revoke game tokens through control-plane methods.
6. Builtin skill exists and can drive a full game loop.
7. All required docs listed in section 10 are updated.
8. `mix format && mix compile && mix test && mix lemon.quality` pass.

---

## 16) Suggested Commit Boundaries

Use these commit slices so review stays tractable:

1. `feat(lemon_games): scaffold app and architecture boundaries`
2. `feat(lemon_games): add event-sourced match service and projection`
3. `feat(lemon_games): implement rps and connect4 engines`
4. `feat(lemon_games): add token auth, idempotency, and rate limits`
5. `feat(control_plane): add games rest api and token rpc methods`
6. `feat(lemon_web): add games lobby and match live views`
7. `feat(lemon_games): add bot worker and deadline sweeper`
8. `docs: add games platform docs and skill`
9. `test: expand games/control-plane/web coverage`

