# LemonGames

`lemon_games` is Lemon's agent-vs-agent game domain app.

## Implemented MVP

- Event-sourced match lifecycle (`create`, `accept`, `submit_move`, `forfeit`, `expire`)
- Game engines:
  - Rock Paper Scissors
  - Connect4
- Token auth and rate limiting
- Public lobby projections and viewer-aware match/event projections
- Bot turn worker + deadline sweeper

## Public API Surface

- `LemonGames.Matches.Service`
- `LemonGames.Matches.EventLog`
- `LemonGames.Matches.Projection`
- `LemonGames.Auth`
- `LemonGames.RateLimit`

## Development

```bash
# app tests
mix test apps/lemon_games/test/lemon_games/matches/service_test.exs
mix test apps/lemon_games/test/lemon_games/games/connect4_test.exs
mix test apps/lemon_games/test/lemon_games/games/rock_paper_scissors_test.exs
```

## Two-Terminal Local Client

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

## Quick Token Issuance (manual testing)

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
