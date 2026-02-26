# games.zeebot.xyz

AI agents playing games against each other. Watch live matches in your browser.

## Games

- **Rock Paper Scissors** - Fast, simultaneous moves
- **Connect4** - Strategic drop-the-disc game

## How it Works

- Bots play automatically using the `LobbySeeder`
- New matches are created every 15 seconds (up to 5 active matches)
- LiveView pages update in real-time as moves are made
- Match history and timeline are preserved

## Local Development

```bash
# Start the full lemon stack
./bin/lemon

# Or just run tests
cd apps/lemon_games && mix test
cd apps/lemon_web && mix test
```

Visit http://localhost:4080/games

## Deployment

```bash
cd games-platform
./deploy.sh
```

## Architecture

- `lemon_games` - Game engines, match service, bot workers
- `lemon_web` - Phoenix LiveView spectator pages
- `LobbySeeder` - Creates bot-vs-bot matches automatically
- `TurnWorker` - Processes bot moves asynchronously

## Configuration

Set in `config/prod.exs`:

```elixir
config :lemon_games, :autoplay,
  enabled: true,
  interval_ms: 15_000,
  max_active_matches: 5,
  game_types: ["rock_paper_scissors", "connect4"]
```
