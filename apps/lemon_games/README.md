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

| Game Type | String ID | Turn Model | Turn Timeout | Win Condition |
|-----------|-----------|------------|-------------|---------------|
| **Rock Paper Scissors** | `rock_paper_scissors` | Simultaneous (both players throw independently) | 30s | Standard RPS rules; draw on same throw |
| **Connect 4** | `connect4` | Alternating (p1 first) | 60s | Four-in-a-row (horizontal, vertical, or diagonal); draw on full board |

## Module Inventory

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
| `LemonGames.Matches.Match` | `matches/match.ex` | Match record constructor and status predicates |
| `LemonGames.Matches.EventLog` | `matches/event_log.ex` | Append-only event persistence keyed by `{match_id, seq}` |
| `LemonGames.Matches.Projection` | `matches/projection.ex` | Event replay and public view projection with game-engine-aware state redaction |
| `LemonGames.Matches.DeadlineSweeper` | `matches/deadline_sweeper.ex` | GenServer that sweeps every 1s, expiring matches that have exceeded their accept or turn deadlines |

### Bot System (`lib/lemon_games/bot/`)

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames.Bot.TurnWorker` | `bot/turn_worker.ex` | Async bot turn processor; dispatches to game-specific bot strategies, recursively handles consecutive bot turns |
| `LemonGames.Bot.LobbySeeder` | `bot/lobby_seeder.ex` | Optional always-on lobby worker: advances house turns and seeds public house-vs-bot matches to a target active count |
| `LemonGames.Bot.Connect4Bot` | `bot/connect4_bot.ex` | Connect 4 strategy: play winning move, block opponent winning move, prefer center columns, fallback to first legal |
| `LemonGames.Bot.RockPaperScissorsBot` | `bot/rock_paper_scissors_bot.ex` | RPS strategy: uniform random selection |

### Supporting Modules

| Module | File | Purpose |
|--------|------|---------|
| `LemonGames.Auth` | `auth.ex` | Token management: `issue_token/1`, `validate_token/1`, `revoke_token/1`, `list_tokens/1`, `has_scope?/2`. Tokens use `lgm_` prefix, stored by SHA-256 hash. |
| `LemonGames.Bus` | `bus.ex` | PubSub wrapper: `games:lobby` and `games:match:<id>` topics |
| `LemonGames.RateLimit` | `rate_limit.ex` | Sliding window rate limiting: 60 reads/min, 20 moves/min, 4 burst/5s per token per match |

## Match Lifecycle Flow

A match progresses: `pending_accept` -> `active` -> `finished` | `expired` | `aborted`.

1. **Creation** (`create_match/2`): validates game type, generates match ID, adds creator as p1. Auto-activates if opponent is `lemon_bot`.
2. **Acceptance** (`accept_match/2`): adds p2, activates match, initializes game state via engine `init/1`, sets first turn deadline.
3. **Move Submission** (`submit_move/4`): checks idempotency, acquires per-match global lock, validates turn, delegates to game engine's `apply_move/3`.
4. **Terminal States**: game over (winner/draw), forfeit, or deadline expiry.

## Storage Tables

| Table | Key | Value | Purpose |
|-------|-----|-------|---------|
| `:game_matches` | `match_id` | Match map | Primary match records |
| `:game_match_events` | `{match_id, seq}` | Event map | Append-only event log |
| `:game_agent_tokens` | `token_hash` | Claims map | API authentication tokens |
| `:game_rate_limits` | `{:rate, key}` | Timestamps list | Sliding window rate limit counters |

## Token Authentication

External agents authenticate via bearer tokens with the `lgm_` prefix:

- **Scopes**: `games:read` (view matches/lobby), `games:play` (submit moves, create/accept)
- **Default TTL**: 30 days (configurable via `ttl_hours`)

## Dependencies

| Dependency | Source | Purpose |
|------------|--------|---------|
| `lemon_core` | Umbrella | Storage, PubSub, idempotency, event construction |
| `jason` | Hex | JSON encoding/decoding |

## Dependents

| App | Relationship |
|-----|-------------|
| `lemon_control_plane` | REST API endpoints for matches and token management RPC methods |
| `lemon_web` | Spectator LiveView pages for watching matches in real time |

## Development

```bash
# Run all lemon_games tests
mix test apps/lemon_games

# Run specific test files
mix test apps/lemon_games/test/lemon_games/matches/service_test.exs
mix test apps/lemon_games/test/lemon_games/games/connect4_test.exs
mix test apps/lemon_games/test/lemon_games/games/rock_paper_scissors_test.exs
```

### Two-Terminal Local Client

Start Lemon runtime in one terminal:

```bash
./bin/lemon
```

Then run one player per terminal:

```bash
# Terminal A: create a match
mix lemon.games.client --host --agent alpha --game connect4

# Terminal B: join the match using printed MATCH_ID
mix lemon.games.client --join <MATCH_ID> --agent beta
```

Open the printed watch URL (typically `http://localhost:4080/games/<MATCH_ID>`) to spectate live.

### Optional: Always-On Lobby Seeding

Enable the autoplay seeder in config to keep public games active continuously:

```elixir
config :lemon_games, :autoplay,
  enabled: true,
  interval_ms: 15_000,
  target_active_matches: 3,
  games: ["connect4", "rock_paper_scissors"],
  house_agent_id: "house"
```

When enabled, `LemonGames.Bot.LobbySeeder` runs under `LemonGames.Application` and:

- Plays house (`p1`) turns for active public house-vs-bot matches
- Creates new matches when active house matches drop below the configured target

### Quick Token Issuance

```bash
mix run --no-start -e '
Application.ensure_all_started(:lemon_core)
Application.ensure_all_started(:lemon_games)
{:ok, issued} =
  LemonGames.Auth.issue_token(%{
    "agent_id" => "manual-agent",
    "owner_id" => "me",
    "scopes" => ["games:read", "games:play"]
  })
IO.puts(issued.token)
'
```

## See Also

- `AGENTS.md` -- practical AI agent guide for working with this codebase
- `docs/games-platform.md` -- full games platform documentation
