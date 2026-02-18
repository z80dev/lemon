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
