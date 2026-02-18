# Lemon Poker

Pure-state no-limit hold'em engine app for the Lemon umbrella.

It currently covers:

- 52-card deck/card mechanics
- 5-7 card hand evaluation (`LemonPoker.HandRank`)
- Multi-player table and seat management
- Blind/button progression
- Full betting-round flow (`fold/check/call/bet/raise`)
- Action legality and bet/raise range validation
- All-in handling, side pots, showdown resolution
- Deterministic seeded or explicit deck support for replay/tests

## Run Tests

```bash
cd /Users/z80/dev/lemon
mix test apps/lemon_poker
```

## Run An Agent Match

```bash
cd /Users/z80/dev/lemon
mix lemon_poker.play --hands 1 --seed 42
mix lemon_poker.play --players 6 --hands 10
```

By default this runs 2 `default` profile agent sessions. Set `--players N` for
`N` seats (`2..9`), and it prints each table action as it happens.

Poker tasks run with runtime overrides that disable Telegram transport and SMS
webhooks in that process, so they do not contend with an already-running
`lemon_gateway`.

They also run a startup assertion and fail fast if Telegram transport or SMS
webhook are unexpectedly active.

By default, poker runtime uses the canonical Lemon store (`~/.lemon/store`),
so provider API keys from Lemon secrets are available in poker agent runs.

If you want a fully isolated poker store, set:

```bash
LEMON_POKER_ISOLATE_STORE=true
```

Optional path override for isolated mode:

```bash
LEMON_POKER_STORE_PATH=~/.lemon/poker-store
```

## Run The Browser UI

```bash
cd /Users/z80/dev/lemon
mix lemon_poker.server --port 4100
```

Then open [http://127.0.0.1:4100](http://127.0.0.1:4100).

What you get:

- Live table visualization (seats, stacks, board, pot, acting seat)
- Real-time action feed and table-talk feed
- Match controls (start/pause/resume/stop)
- Runtime config from the browser (`players`, `hands`, blinds, stack, profile, etc.)
- WebSocket streaming (`/ws`) and JSON control APIs (`/api/*`)

Table-talk policy:

- During an active hand, player table-talk that appears to reveal hole cards
  (ranks/suits) is blocked, even if the player has folded.

## Quick Usage

```elixir
alias LemonPoker.Table

table =
  Table.new("table-1", max_seats: 6, small_blind: 50, big_blind: 100)
  |> then(fn t ->
    {:ok, t} = Table.seat_player(t, 1, "p1", 1_000)
    {:ok, t} = Table.seat_player(t, 2, "p2", 1_000)
    {:ok, t} = Table.seat_player(t, 3, "p3", 1_000)
    t
  end)

{:ok, table} = Table.start_hand(table, seed: 42)
{:ok, legal} = Table.legal_actions(table)
{:ok, table} = Table.act(table, legal.seat, :call)
```
