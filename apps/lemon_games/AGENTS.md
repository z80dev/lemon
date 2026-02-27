# LemonGames Agent Guide

## Quick Orientation

LemonGames is the game domain engine in the Lemon umbrella. It owns game rules, match lifecycle, bot play, token auth, and rate limiting. It does NOT own HTTP routing or LiveView rendering -- those belong to `lemon_control_plane` and `lemon_web` respectively.

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
| `lib/lemon_games/games/connect4.ex` | Connect 4 engine: 7x6 board, gravity drops, 4-direction win check | Fixing Connect 4 rules |
| `lib/lemon_games/games/rock_paper_scissors.ex` | RPS engine: simultaneous throws, redacted public state until resolved | Fixing RPS rules |

### Match Lifecycle Layer

| File | What it does | When to touch it |
|------|-------------|-----------------|
| `lib/lemon_games/matches/service.ex` | Main API: create, accept, move, forfeit, expire, get, list | Adding match operations or changing lifecycle |
| `lib/lemon_games/matches/match.ex` | Match record shape, constructors, status predicates, timeout values | Changing match schema or timeouts |
| `lib/lemon_games/matches/event_log.ex` | Append-only event storage keyed by `{match_id, seq}` | Changing event storage |
| `lib/lemon_games/matches/projection.ex` | Event replay and public view construction with redaction | Changing what spectators/players see |
| `lib/lemon_games/matches/deadline_sweeper.ex` | GenServer sweeping expired matches every 1s | Changing expiry logic or sweep interval |

### Bot System

| File | What it does | When to touch it |
|------|-------------|-----------------|
| `lib/lemon_games/bot/turn_worker.ex` | Async bot turn dispatcher; routes to game-specific strategy | Adding new game type bots |
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

### Step 1: Implement the behaviour

Create `lib/lemon_games/games/your_game.ex`:

```elixir
defmodule LemonGames.Games.YourGame do
  @behaviour LemonGames.Games.Game

  @impl true
  def game_type, do: "your_game"

  @impl true
  def init(_opts), do: %{"your" => "initial_state", "winner" => nil}

  @impl true
  def legal_moves(state, slot), do: [%{"kind" => "your_move"}]

  @impl true
  def apply_move(state, slot, move) do
    # Return {:ok, new_state} or {:error, :illegal_move, "reason"}
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

All state must use **string keys**. `winner/1` must return `"p1"`, `"p2"`, `"draw"`, or `nil`.

### Step 2: Register in the registry

Edit `lib/lemon_games/games/registry.ex`:

```elixir
@engines %{
  "rock_paper_scissors" => LemonGames.Games.RockPaperScissors,
  "connect4" => LemonGames.Games.Connect4,
  "your_game" => LemonGames.Games.YourGame
}
```

### Step 3: Set turn timeout

Edit `lib/lemon_games/matches/match.ex`:

```elixir
def turn_timeout_ms("your_game"), do: 45_000
```

### Step 4: Add a bot strategy

Create `lib/lemon_games/bot/your_game_bot.ex` and add a clause in `turn_worker.ex`.

### Step 5: Write tests and update docs

## Testing Guidance

```bash
mix test apps/lemon_games
mix test apps/lemon_games/test/lemon_games/games/connect4_test.exs
mix test apps/lemon_games --trace
```

### Conventions

- Game engine tests use `async: true` (pure functions, no shared state)
- Service and auth tests use `async: false` (shared ETS tables) and clean store tables in `setup`
- Store tables to clean: `:game_matches`, `:game_match_events`, `:game_agent_tokens`, `:game_rate_limits`

## Common Patterns and Gotchas

- **String keys everywhere**: all maps use string keys for `LemonCore.Store` compatibility
- **Error tuples**: all Service errors follow `{:error, atom_code, string_message}`
- **Move format**: maps with a `"kind"` key (e.g., `%{"kind" => "drop", "column" => 3}`)
- **Bot turn chaining**: `TurnWorker.maybe_play_bot_turn/1` is recursive for bot-vs-bot scenarios
- **Idempotency**: move submissions require an idempotency key; reuse with different actor/move returns `:idempotency_conflict`

## Connections to Other Apps

### Upstream

- **`lemon_core`**: Storage, PubSub, idempotency, config

### Downstream

- **`lemon_control_plane`**: REST API endpoints, token management RPC methods
- **`lemon_web`**: Spectator LiveView pages subscribed to `LemonGames.Bus`
