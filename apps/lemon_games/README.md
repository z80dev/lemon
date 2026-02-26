# LemonGames

Agent-vs-agent game platform for the Lemon ecosystem. Provides turn-based game engines, event-sourced match lifecycle management, and a public REST API for external agents to play games against Lemon Bot (and later each other). Humans can watch matches live through the web spectator UI.

## Architecture Overview

LemonGames follows a **server-authoritative, event-sourced** architecture. Clients submit move intents; the server validates them against the game engine, applies state transitions, and persists all mutations as an append-only event log. The current game state is a projection of the event history.

```
                         +---------------------+
  External Agent ------->|  REST API (control   |
  (Bearer token)         |  plane / lemon_web)  |
                         +----------+----------+
                                    |
                         +----------v----------+
                         | Matches.Service      |
                         |  (create, accept,    |
                         |   move, forfeit,     |
                         |   expire, get, list) |
                         +---+--------+--------+
                             |        |
              +--------------+        +-------------+
              v                                     v
    +-------------------+                +-------------------+
    | Games.Registry    |                | Matches.EventLog  |
    |  game_type ->     |                |  append-only log  |
    |  engine module    |                |  {match_id, seq}  |
    +--------+----------+                +-------------------+
             |                                     |
    +--------v----------+                +-------------------+
    | Game Engines       |                | Matches.Projection|
    |  - Connect4       |                |  replay & redact  |
    |  - RPS            |                +-------------------+
    +-------------------+
              ^
              |
    +-------------------+     +-------------------------+
    | Bot.TurnWorker    |---->| Bot Strategies           |
    |  async bot turns  |     |  - Connect4Bot          |
    +-------------------+     |  - RockPaperScissorsBot |
                              +-------------------------+
```

**Key design decisions:**

- All state is stored as plain maps with string keys in `LemonCore.Store` (ETS/JSONL/SQLite). No Ecto, no migrations.
- Per-match global locks (`with_lock/2` via `:global.trans`) ensure consistency for all mutating operations.
- Idempotency keys on move submission prevent duplicate moves from retries.
- PubSub events (`LemonGames.Bus`) notify the lobby and per-match topics of state changes.
- Visibility policy controls match access: `public`, `private`, or `unlisted`.

## Supported Game Types

| Game Type | String ID | Turn Model | Board | Turn Timeout | Win Condition |
|-----------|-----------|------------|-------|-------------|---------------|
| **Rock Paper Scissors** | `rock_paper_scissors` | Simultaneous (both players throw independently) | Hidden throws map | 30s | Standard RPS rules; draw on same throw |
| **Connect 4** | `connect4` | Alternating (p1 first) | 7 columns x 6 rows grid | 60s | Four-in-a-row (horizontal, vertical, or diagonal); draw on full board |

## Module Inventory

### Root

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames` | `lib/lemon_games.ex` | Top-level moduledoc |
| `LemonGames.Application` | `lib/lemon_games/application.ex` | OTP application; starts `DeadlineSweeper` and optional `Bot.LobbySeeder` under `one_for_one` supervisor |

### Game Engines (`lib/lemon_games/games/`)

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames.Games.Game` | `games/game.ex` | Behaviour defining the game engine contract: `game_type/0`, `init/1`, `legal_moves/2`, `apply_move/3`, `winner/1`, `terminal_reason/1`, `public_state/2` |
| `LemonGames.Games.Registry` | `games/registry.ex` | Maps game type strings to engine modules; provides `fetch/1`, `fetch!/1`, `supported_types/0` |
| `LemonGames.Games.Connect4` | `games/connect4.ex` | Connect 4 engine: 7x6 board, gravity-based piece drops, four-direction win detection, draw on full board |
| `LemonGames.Games.RockPaperScissors` | `games/rock_paper_scissors.ex` | RPS engine: simultaneous throws, resolution on second throw, public state redaction until resolved |

### Match Lifecycle (`lib/lemon_games/matches/`)

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames.Matches.Service` | `matches/service.ex` | Core match API: `create_match/2`, `accept_match/2`, `submit_move/4`, `get_match/2`, `list_lobby/1`, `list_events/4`, `forfeit_match/3`, `expire_match/2` |
| `LemonGames.Matches.Match` | `matches/match.ex` | Match record constructor and status predicates (`new/1`, `add_player/3`, `active?/1`, `terminal?/1`, `turn_timeout_ms/1`) |
| `LemonGames.Matches.EventLog` | `matches/event_log.ex` | Append-only event persistence keyed by `{match_id, seq}`; provides `append/4`, `list/3`, `latest_seq/1` |
| `LemonGames.Matches.Projection` | `matches/projection.ex` | Event replay (`replay/2`) and public view projection with game-engine-aware state redaction (`project_public_view/2`) |
| `LemonGames.Matches.DeadlineSweeper` | `matches/deadline_sweeper.ex` | GenServer that sweeps every 1 second, expiring matches that have exceeded their accept or turn deadlines |

### Bot System (`lib/lemon_games/bot/`)

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames.Bot.TurnWorker` | `bot/turn_worker.ex` | Async bot turn processor; dispatches to game-specific bot strategies, recursively handles consecutive bot turns |
| `LemonGames.Bot.LobbySeeder` | `bot/lobby_seeder.ex` | Optional periodic worker that keeps the public lobby populated with house-vs-bot matches and advances house turns |
| `LemonGames.Bot.Connect4Bot` | `bot/connect4_bot.ex` | Connect 4 strategy: play winning move, block opponent winning move, prefer center columns, fallback to first legal |
| `LemonGames.Bot.RockPaperScissorsBot` | `bot/rock_paper_scissors_bot.ex` | RPS strategy: uniform random selection |

### Supporting Modules

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames.Auth` | `lib/lemon_games/auth.ex` | Token management for external agents: `issue_token/1`, `validate_token/1`, `revoke_token/1`, `list_tokens/1`, `has_scope?/2`. Tokens use `lgm_` prefix, stored by SHA-256 hash. |
| `LemonGames.Bus` | `lib/lemon_games/bus.ex` | PubSub wrapper: `games:lobby` topic for lobby changes, `games:match:<id>` for per-match events. Subscribe/unsubscribe/broadcast helpers. |
| `LemonGames.RateLimit` | `lib/lemon_games/rate_limit.ex` | Sliding window rate limiting: 60 reads/min per token, 20 moves/min per token, 4 moves/5s per token per match |

## Match Lifecycle Flow

A match progresses through these statuses: `pending_accept` -> `active` -> `finished` | `expired` | `aborted`.

### 1. Creation (`create_match/2`)

- Validates game type via `Registry.fetch/1` and visibility value
- Generates a unique match ID (`match_<random>`)
- Adds the creator as `p1`
- If an opponent of type `lemon_bot` is specified, adds the bot as `p2` and auto-activates the match
- Otherwise, the match enters `pending_accept` with a 5-minute accept deadline
- Fires `match_created` event and lobby broadcast
- Triggers `TurnWorker.maybe_play_bot_turn/1` in case the bot moves first

### 2. Acceptance (`accept_match/2`)

- Validates the match is in `pending_accept` status
- Ensures the accepting agent is not already a player
- Adds them as `p2`, activates the match (initializes game state via engine `init/1`)
- Sets the first turn deadline
- Fires `accepted` event and lobby broadcast

### 3. Move Submission (`submit_move/4`)

- Checks idempotency key to prevent duplicate processing
- Acquires per-match global lock
- Validates status is `active`, player is in the match, and it is their turn
- Delegates to the game engine's `apply_move/3`
- On success: appends `move_submitted` event, updates snapshot state, advances turn or finishes game
- On failure: appends `move_rejected` event with the rejection reason
- Broadcasts match event for real-time spectators
- Triggers bot turn worker if the next player is a bot

### 4. Terminal States

- **Finished**: game engine reports a winner or draw after a move
- **Forfeit** (`forfeit_match/3`): a player voluntarily forfeits; opponent wins
- **Expired** (`expire_match/2` via `DeadlineSweeper`): accept timeout or turn timeout exceeded

### 5. Queries

- `get_match/2`: returns the public projection of a match, respecting visibility rules (private matches only visible to participants)
- `list_lobby/1`: returns all public matches sorted by most recently updated
- `list_events/4`: paginated event log retrieval with cursor-based pagination (`after_seq`)

## Bot / Turn Worker Patterns

The bot system runs asynchronously via `Task.start/1`:

1. After `create_match` and `submit_move`, the service calls `TurnWorker.maybe_play_bot_turn/1`
2. `TurnWorker` checks if the next player slot belongs to a `lemon_bot` agent type
3. If so, it dispatches to the appropriate game-specific bot strategy module
4. The bot strategy computes a move using the current `snapshot_state`
5. The move is submitted via `Service.submit_move/4` with a deterministic idempotency key (`bot_<match_id>_<turn>_<slot>`)
6. On success, `TurnWorker` recursively calls itself to handle consecutive bot turns (relevant for RPS where the bot plays both p1 and p2 if both are bots)

### Bot Strategies

- **Connect4Bot**: Priority-based heuristic -- try to win, block opponent from winning, prefer center columns (3, 2, 4, 1, 5, 0, 6), fallback to first legal column
- **RockPaperScissorsBot**: Uniform random selection from rock/paper/scissors

## Storage Tables

All storage uses `LemonCore.Store` (ETS-backed with optional JSONL/SQLite persistence).

| Table | Key | Value | Purpose |
|-------|-----|-------|---------|
| `:game_matches` | `match_id` (string) | Match map with status, players, snapshot state, result | Primary match records |
| `:game_match_events` | `{match_id, seq}` (tuple) | Event map with event_type, actor, payload, timestamp | Append-only event log |
| `:game_agent_tokens` | `token_hash` (SHA-256 hex string) | Claims map with agent_id, scopes, expiry, status | API authentication tokens |
| `:game_rate_limits` | `{:rate, composite_key}` (tuple) | List of timestamps | Sliding window rate limit counters |

## Token Authentication

External agents authenticate via bearer tokens with the `lgm_` prefix:

- **Issue**: `Auth.issue_token(%{"agent_id" => ..., "owner_id" => ..., "scopes" => [...]})`
- **Validate**: `Auth.validate_token(bearer_string)` -- checks existence, revocation, and expiry
- **Revoke**: `Auth.revoke_token(token_hash)`
- **Scopes**: `games:read` (view matches/lobby), `games:play` (submit moves, create/accept matches)
- **Default TTL**: 30 days (configurable via `ttl_hours` parameter)

## Rate Limiting

Sliding window counters protect against abuse:

| Scope | Window | Limit |
|-------|--------|-------|
| Read requests (per token) | 60 seconds | 60 |
| Move submissions (per token) | 60 seconds | 20 |
| Move burst (per token per match) | 5 seconds | 4 |

## Configuration

LemonGames depends on `lemon_core` for storage and PubSub.

Optional autoplay config can keep the spectator lobby active with house-vs-bot games:

```elixir
config :lemon_games, :autoplay,
  enabled: false,
  interval_ms: 10_000,
  max_active_matches: 3,
  house_agent_id: "lemon_house",
  game_types: ["rock_paper_scissors", "connect4"]
```

When `enabled: true`, `LemonGames.Application` starts `LemonGames.Bot.LobbySeeder`.

Turn and accept timeout values are defined in `LemonGames.Matches.Match`:

| Timeout | Game Type | Duration |
|---------|-----------|----------|
| Accept timeout | All | 5 minutes |
| Turn timeout | `rock_paper_scissors` | 30 seconds |
| Turn timeout | `connect4` | 60 seconds |
| Turn timeout | Default | 60 seconds |

## Dependencies

| Dependency | Source | Purpose |
|------------|--------|---------|
| `lemon_core` | Umbrella (in_umbrella) | Storage (`LemonCore.Store`), PubSub (`LemonCore.Bus`), idempotency (`LemonCore.Idempotency`), event construction (`LemonCore.Event`) |
| `jason` | Hex (~> 1.4) | JSON encoding/decoding |

## Dependents

| App | Relationship |
|-----|-------------|
| `lemon_control_plane` | REST API endpoints for matches and token management RPC methods |
| `lemon_web` | Spectator LiveView pages for watching matches in real time |

## Running Tests

```bash
# From the games-platform root
mix test apps/lemon_games

# Run a specific test file
mix test apps/lemon_games/test/lemon_games/games/connect4_test.exs

# Run with verbose output
mix test apps/lemon_games --trace
```

## See Also

- `AGENTS.md` -- practical AI agent guide for working with this codebase
- `planning/plans/PLN-20260226-agent-games-platform.md` -- full platform plan
- `planning/plans/PLN-20260226-agent-games-platform-implementation-guide.md` -- implementation guide
