# LemonGames Agent Guide

## Quick Orientation

LemonGames is the game domain engine inside the `games-platform` Elixir umbrella. It owns game rules, match lifecycle, bot play, token auth, and rate limiting. It does NOT own HTTP routing or LiveView rendering -- those belong to `lemon_control_plane` and `lemon_web` respectively.

Core principles:
- **Server-authoritative**: clients submit move intents, never full state
- **Event-sourced**: all game history stored as append-only events; current state is a projection
- **Plain maps with string keys**: no Ecto schemas; storage via `LemonCore.Store` (ETS/JSONL/SQLite)
- **Per-match global locks**: all mutating operations go through `:global.trans` for consistency
- **Visibility policy**: match `visibility` must be one of `public`, `private`, or `unlisted`

## Key Files and Purposes

### Game Engine Layer

| File | What it does | When to touch it |
|------|-------------|-----------------|
| `lib/lemon_games/games/game.ex` | Behaviour contract for all game engines (7 callbacks) | Adding new callback requirements |
| `lib/lemon_games/games/registry.ex` | Maps game type strings to engine modules | Registering new game engines |
| `lib/lemon_games/games/connect4.ex` | Connect 4 engine: 7x6 board, gravity drops, 4-direction win check | Fixing Connect 4 rules or improving win detection |
| `lib/lemon_games/games/rock_paper_scissors.ex` | RPS engine: simultaneous throws, redacted public state until resolved | Fixing RPS rules |

### Match Lifecycle Layer

| File | What it does | When to touch it |
|------|-------------|-----------------|
| `lib/lemon_games/matches/service.ex` | Main API: create, accept, move, forfeit, expire, get, list | Adding new match operations or changing lifecycle flow |
| `lib/lemon_games/matches/match.ex` | Match record shape, constructors, status predicates, timeout values | Changing match schema, adding fields, adjusting timeouts |
| `lib/lemon_games/matches/event_log.ex` | Append-only event storage keyed by `{match_id, seq}` | Changing event storage or adding event types |
| `lib/lemon_games/matches/projection.ex` | Event replay and public view construction with redaction | Changing what spectators/players see |
| `lib/lemon_games/matches/deadline_sweeper.ex` | GenServer sweeping expired matches every 1s | Changing expiry logic or sweep interval |

### Bot System

| File | What it does | When to touch it |
|------|-------------|-----------------|
| `lib/lemon_games/bot/turn_worker.ex` | Async bot turn dispatcher; routes to game-specific strategy | Adding support for new game type bots |
| `lib/lemon_games/bot/connect4_bot.ex` | Connect 4 heuristic: win > block > center > first legal | Improving bot intelligence |
| `lib/lemon_games/bot/rock_paper_scissors_bot.ex` | RPS: uniform random | Improving bot strategy |

### Auth and Infrastructure

| File | What it does | When to touch it |
|------|-------------|-----------------|
| `lib/lemon_games/auth.ex` | Token CRUD: issue (`lgm_` prefix), validate, revoke, list, scope check | Changing auth model or token format |
| `lib/lemon_games/bus.ex` | PubSub wrapper for `games:lobby` and `games:match:<id>` topics | Adding new event broadcast types |
| `lib/lemon_games/rate_limit.ex` | Sliding window rate limiters (60 reads/min, 20 moves/min, 4 burst/5s) | Adjusting rate limits |
| `lib/lemon_games/application.ex` | OTP supervisor tree; starts `DeadlineSweeper` | Adding new supervised processes |

## How to Add a New Game Engine

This is the most common extension task. Follow these steps exactly:

### Step 1: Implement the behaviour

Create `lib/lemon_games/games/your_game.ex`:

```elixir
defmodule LemonGames.Games.YourGame do
  @moduledoc "YourGame engine."
  @behaviour LemonGames.Games.Game

  @impl true
  def game_type, do: "your_game"

  @impl true
  def init(_opts), do: %{"your" => "initial_state", "winner" => nil}

  @impl true
  def legal_moves(state, slot), do: [%{"kind" => "your_move"}]

  @impl true
  def apply_move(state, slot, move) do
    # Validate and apply; return {:ok, new_state} or {:error, :illegal_move, "reason"}
  end

  @impl true
  def winner(state), do: state["winner"]

  @impl true
  def terminal_reason(state) do
    case state["winner"] do
      nil -> nil
      "draw" -> "draw"
      _ -> "winner"
    end
  end

  @impl true
  def public_state(state, _viewer), do: state
end
```

All state must use **string keys** (not atoms). The `winner/1` return value must be `"p1"`, `"p2"`, `"draw"`, or `nil`.

### Step 2: Register in the registry

Edit `lib/lemon_games/games/registry.ex` and add to the `@engines` map:

```elixir
@engines %{
  "rock_paper_scissors" => LemonGames.Games.RockPaperScissors,
  "connect4" => LemonGames.Games.Connect4,
  "your_game" => LemonGames.Games.YourGame
}
```

### Step 3: Set turn timeout

Edit `lib/lemon_games/matches/match.ex` and add a clause to `turn_timeout_ms/1`:

```elixir
def turn_timeout_ms("your_game"), do: 45_000
```

### Step 4: Handle turn model in Service

If your game uses something other than simple alternating turns (like RPS's simultaneous model), update these private functions in `lib/lemon_games/matches/service.ex`:

- `initial_next_player/1` -- who moves first
- `compute_alternating_next/1` -- how turns advance
- `assert_turn/2` -- turn validation (RPS allows both players to move independently)

### Step 5: Add a bot strategy

Create `lib/lemon_games/bot/your_game_bot.ex` implementing `choose_move/2`:

```elixir
defmodule LemonGames.Bot.YourGameBot do
  @spec choose_move(map(), String.t()) :: map()
  def choose_move(state, slot) do
    # Return a legal move map
  end
end
```

Then add a clause to `choose_move/3` in `lib/lemon_games/bot/turn_worker.ex`:

```elixir
defp choose_move("your_game", state, slot) do
  LemonGames.Bot.YourGameBot.choose_move(state, slot)
end
```

### Step 6: Write tests

Create test files:
- `test/lemon_games/games/your_game_test.exs` -- engine unit tests covering all win/lose/draw/illegal-move cases
- Add integration coverage in the service test for full lifecycle with the new game type

### Step 7: Update documentation

Update `README.md` and `AGENTS.md` with the new game type details.

## Testing Guidance

### Test Structure

```
test/
  lemon_games_test.exs                          # Application start smoke test
  lemon_games/
    auth_test.exs                               # Token issue/validate/revoke/list/scope
    rate_limit_test.exs                         # Rate limit window enforcement
    games/
      connect4_test.exs                         # Engine: all 4 win directions, draw, illegal moves
      rock_paper_scissors_test.exs              # Engine: all 9 outcomes, redaction, illegal moves
    matches/
      service_test.exs                          # Full lifecycle: create, accept, move, forfeit, expire, idempotency
      projection_test.exs                       # Event replay and public view projection
```

### Running Tests

```bash
# All lemon_games tests
mix test apps/lemon_games

# Single file
mix test apps/lemon_games/test/lemon_games/games/connect4_test.exs

# Single test by line number
mix test apps/lemon_games/test/lemon_games/games/connect4_test.exs:25

# Verbose
mix test apps/lemon_games --trace
```

### Test Conventions

- Game engine tests use `async: true` (pure functions, no shared state)
- Service and auth tests use `async: false` (shared ETS tables) and clean store tables in `setup`
- Helper functions like `drop/3`, `drop_seq/2`, `play/2` are defined locally in test modules for concise test bodies
- Service tests use a `create_bot_match/1` helper that creates a match with a lemon_bot opponent for quick active-match setup
- Store tables to clean between tests: `:game_matches`, `:game_match_events`, `:game_agent_tokens`, `:game_rate_limits`

### What to Test for a New Game Engine

At minimum, cover:
1. `game_type/0` returns the correct string
2. `init/1` returns a valid initial state
3. `legal_moves/2` returns correct moves for fresh state and finished state (empty list)
4. `apply_move/3` for every legal move kind
5. `apply_move/3` rejection cases: invalid format, out-of-range values, move after game over
6. All win conditions (one per player)
7. Draw condition if applicable
8. `winner/1` returns `nil` on fresh state, correct value after terminal
9. `terminal_reason/1` returns `nil`, `"draw"`, or `"winner"` as appropriate
10. `public_state/2` redaction behavior (if the game has hidden information)

## Storage Tables

| Table | Key | Purpose |
|-------|-----|---------|
| `:game_matches` | `match_id` | Match records with status, players, snapshot |
| `:game_match_events` | `{match_id, seq}` | Append-only event log |
| `:game_agent_tokens` | `token_hash` | API tokens for external agents |
| `:game_rate_limits` | composite | Per-token and per-match rate limit counters |

## Connections to Other Apps

### Upstream Dependencies

- **`lemon_core`**: Storage (`LemonCore.Store`), PubSub (`LemonCore.Bus`, `LemonCore.Event`), idempotency (`LemonCore.Idempotency`), config

### Downstream Dependents

- **`lemon_control_plane`**: Exposes the games REST API (match CRUD, token management RPC methods). Routes HTTP requests to `LemonGames.Matches.Service` and `LemonGames.Auth`.
- **`lemon_web`**: Provides the spectator LiveView UI. Subscribes to `LemonGames.Bus` topics for real-time match updates.

### Data Flow

```
HTTP Request -> lemon_control_plane (auth check via LemonGames.Auth)
             -> lemon_control_plane (rate check via LemonGames.RateLimit)
             -> LemonGames.Matches.Service (business logic)
             -> LemonCore.Store (persistence)
             -> LemonGames.Bus (PubSub broadcast)
             -> lemon_web LiveView (spectator receives update)
```

## Common Patterns and Gotchas

### String Keys Everywhere

All maps use string keys, not atoms. This is a project-wide convention for `LemonCore.Store` compatibility:

```elixir
# Correct
%{"game_type" => "connect4", "winner" => nil}

# Wrong -- will cause subtle bugs
%{game_type: "connect4", winner: nil}
```

### Error Tuple Convention

All error returns from Service follow `{:error, atom_code, string_message}`:

```elixir
{:error, :illegal_move, "column out of range"}
{:error, :not_found, "match not found"}
{:error, :wrong_turn, "not your turn"}
{:error, :invalid_state, "expected status active, got finished"}
```

### Move Format Convention

Moves are maps with a `"kind"` key that identifies the move type:

```elixir
%{"kind" => "drop", "column" => 3}         # Connect 4
%{"kind" => "throw", "value" => "rock"}     # RPS
```

### Bot Turn Chaining

`TurnWorker.maybe_play_bot_turn/1` is recursive: after a bot plays, it checks if the next player is also a bot. This handles scenarios where both players are bots (e.g., demo matches). The idempotency key format `bot_<match_id>_<turn>_<slot>` prevents duplicate bot moves.

### Deadline Sweeper

The `DeadlineSweeper` GenServer runs every 1 second and expires matches where `deadline_at_ms < now`. It distinguishes between `accept_timeout` (match never accepted) and `turn_timeout` (player ran out of time). Terminal matches (`finished`, `expired`, `aborted`) are skipped.

### Visibility Rules

- `public`: visible to everyone including spectators
- `unlisted`: visible to everyone but not listed in lobby
- `private`: visible only to the match creator and players

### Idempotency

Move submissions require an idempotency key. If the same key is resubmitted with the same actor and move, the cached result is returned. If the key is reused with a different actor or move, an `:idempotency_conflict` error is returned.
