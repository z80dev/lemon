# LemonSimUi

Phoenix LiveView web interface for observing and interacting with `lemon_sim` simulations in real time. This OTP application provides a browser-based dashboard that connects to the simulation harness, displays live state, and optionally accepts human player moves for supported domains.

## Architecture

```
lemon_sim (Runner, Store, Bus, all domain examples)
      ^
      |  (umbrella dependency)
      |
lemon_sim_ui
  |-- LemonSimUi.SimManager         GenServer: start/stop/run simulation processes
  |-- LemonSimUi.SimDashboardLive   Dashboard LiveView for lobby and sim detail
  |-- LemonSimUi.SpectatorLive      Public read-only werewolf spectator LiveView
  |-- LemonSimUi.SimHelpers         Pure helpers: domain inference, labels, colors
  |-- LemonSimUi.Live.Components.*  Stateless function components per domain board
  |-- LemonSimUi.Endpoint           Bandit-backed Phoenix endpoint
```

`SimManager` owns all running simulation tasks under a `DynamicSupervisor`. It drives `LemonSim.Runner.step/3` in a loop, writes state to `LemonSim.Store` after each step, and publishes `LemonCore.Bus` events so the LiveView receives push updates without polling.

The LiveView transport is websocket-only. `LemonSimUi.Endpoint` disables the `/live/longpoll` transport, and the browser client connects without enabling a long-poll fallback.

`SimDashboardLive` subscribes to two topics:

- `SimManager.lobby_topic/0` — for sim list changes (start, stop, finish)
- `LemonSim.Bus` topic for the currently viewed sim — for per-step world updates

The dashboard routes (`/` and `/sims/:sim_id`) are handled by `SimDashboardLive` using `live_action` (`:index` and `:show`). Public werewolf spectator viewing is served separately at `/watch/:sim_id` by `SpectatorLive`.

Admin surfaces are intended to be private. When `LEMON_SIM_UI_ACCESS_TOKEN` is set, the dashboard (`/`, `/sims/:sim_id`) and the JSON admin API require either `Authorization: Bearer <token>` or `?token=<token>`. The spectator route (`/watch/:sim_id`) and `/healthz` remain public.

### Supported Simulation Domains

| Domain | Atom | Notes |
|---|---|---|
| Tic Tac Toe | `:tic_tac_toe` | 2-player, optional human control |
| Skirmish | `:skirmish` | Tactical grid combat, optional human control, map presets |
| Werewolf | `:werewolf` | Hidden-information social deduction, per-seat model assignment |
| Stock Market | `:stock_market` | Multi-trader arena, per-seat model assignment |
| Survivor | `:survivor` | Elimination reality format, per-seat model assignment |
| Space Station | `:space_station` | Social deduction in a crew setting, per-seat model assignment |
| Auction | `:auction` | Bidding sim |
| Diplomacy | `:diplomacy` | Faction negotiation and territory control |
| Dungeon Crawl | `:dungeon_crawl` | Cooperative party-based dungeon run |

### Multi-Model Assignment

For social-deduction and multi-player domains (Werewolf, Stock Market, Survivor, Space Station), each player seat can be assigned a distinct model from the launch form. `SimManager` builds a `model_assignments` map keyed by the domain's canonical actor ID and uses an `on_before_step` callback to switch the active model before each turn. For Werewolf, those IDs are villager names (`"Alice"`, `"Bram"`, etc.), not `player_n` seat labels. All provider credentials are resolved through `LemonSim.GameHelpers.Config`.

Werewolf character lore for spectator mode is generated asynchronously after sim launch. The sim starts immediately, then `SimManager` merges the generated `character_profiles` into the stored state and broadcasts an update when they are ready.

### Interactive Mode

For Tic Tac Toe and Skirmish, the user can select a team at launch. On human turns:

- The runner process blocks in `receive` waiting for `{:human_move, event}`.
- The LiveView captures click events on the board and calls `SimManager.submit_human_move/2`.
- The `SimManager` forwards the event as a message to the runner process.
- Human turns time out after 5 minutes.

## Module Inventory

| Module | File | Purpose |
|---|---|---|
| `LemonSimUi.Application` | `lib/lemon_sim_ui/application.ex` | Starts `Telemetry`, `SimRunnerSupervisor`, `SimManager`, `Endpoint` |
| `LemonSimUi.SimManager` | `lib/lemon_sim_ui/sim_manager.ex` | GenServer: lifecycle and runner loop for all active sims |
| `LemonSimUi.SimDashboardLive` | `lib/lemon_sim_ui/live/sim_dashboard_live.ex` | Lobby + sim detail LiveView; handles sim launch and admin/detail events |
| `LemonSimUi.SpectatorLive` | `lib/lemon_sim_ui/live/spectator_live.ex` | Public shareable werewolf watcher with no admin controls |
| `LemonSimUi.AdminSimController` | `lib/lemon_sim_ui/controllers/admin_sim_controller.ex` | Protected JSON API for starting and stopping sims remotely |
| `LemonSimUi.HealthController` | `lib/lemon_sim_ui/controllers/health_controller.ex` | Public health check used by load balancers and smoke tests |
| `LemonSimUi.SimHelpers` | `lib/lemon_sim_ui/sim_helpers.ex` | Domain type inference, status labels, badge colors, world summaries |
| `LemonSimUi.Live.Components.EventLog` | `lib/lemon_sim_ui/live/components/event_log.ex` | Renders `recent_events` with per-kind color coding |
| `LemonSimUi.Live.Components.PlanHistory` | `lib/lemon_sim_ui/live/components/plan_history.ex` | Renders `plan_history` steps with summary and rationale |
| `LemonSimUi.Live.Components.MemoryViewer` | `lib/lemon_sim_ui/live/components/memory_viewer.ex` | Reads scoped `LemonSim.Memory.Tools` files for the viewed sim |
| `LemonSimUi.Live.Components.TicTacToeBoard` | `lib/lemon_sim_ui/live/components/tic_tac_toe_board.ex` | Renders 3x3 board; emits `human_move` click events |
| `LemonSimUi.Live.Components.SkirmishBoard` | `lib/lemon_sim_ui/live/components/skirmish_board.ex` | Grid board with terrain, unit rosters, kill feed, interactive tactical controls |
| `LemonSimUi.Live.Components.WerewolfBoard` | `lib/lemon_sim_ui/live/components/werewolf_board.ex` | Player role cards, vote tallies, phase/day display |
| `LemonSimUi.Live.Components.StockMarketBoard` | `lib/lemon_sim_ui/live/components/stock_market_board.ex` | Portfolio and price tracking display |
| `LemonSimUi.Live.Components.SurvivorBoard` | `lib/lemon_sim_ui/live/components/survivor_board.ex` | Tribe and elimination history display |
| `LemonSimUi.Live.Components.SpaceStationBoard` | `lib/lemon_sim_ui/live/components/space_station_board.ex` | Crew status and station systems display |
| `LemonSimUi.Live.Components.AuctionBoard` | `lib/lemon_sim_ui/live/components/auction_board.ex` | Lot and bidder state display |
| `LemonSimUi.Live.Components.DiplomacyBoard` | `lib/lemon_sim_ui/live/components/diplomacy_board.ex` | Territory map and faction negotiation display |
| `LemonSimUi.Live.Components.DungeonCrawlBoard` | `lib/lemon_sim_ui/live/components/dungeon_crawl_board.ex` | Party health, room progress, and encounter display |
| `LemonSimUi.Router` | `lib/lemon_sim_ui/router.ex` | Routes `/` and `/sims/:sim_id` to `SimDashboardLive`, plus public `/watch/:sim_id` to `SpectatorLive` |
| `LemonSimUi.Endpoint` | `lib/lemon_sim_ui/endpoint.ex` | Bandit HTTP server, LiveView socket, static asset serving |
| `LemonSimUi.CoreComponents` | `lib/lemon_sim_ui/components/core_components.ex` | Phoenix-generated shared form/flash/button components |

## Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| `lemon_core` | Umbrella | `LemonCore.Bus` for pubsub, `LemonCore.Store` via `LemonSim.Store`, config helpers |
| `lemon_sim` | Umbrella | `Runner`, `Store`, `Bus`, all domain examples and `GameHelpers` |
| `phoenix` | Hex (~> 1.7) | HTTP and LiveView framework |
| `phoenix_html` | Hex (~> 4.1) | HTML helpers |
| `phoenix_live_view` | Hex (~> 1.0) | Server-rendered real-time UI |
| `phoenix_live_reload` | Hex (~> 1.5, dev only) | Hot code reloading in development |
| `gettext` | Hex (~> 0.26) | Internationalisation support |
| `jason` | Hex (~> 1.4) | JSON encoding/decoding |
| `bandit` | Hex (~> 1.5) | HTTP server (replaces Cowboy) |
| `lazy_html` | Hex (>= 0.1.0, test only) | HTML parsing in LiveView tests |

## Usage

The app starts automatically as part of the umbrella. To start the umbrella in development:

```bash
mix phx.server
# or
iex -S mix phx.server
```

The dashboard is available at `http://localhost:4000` (port configured in `config/dev.exs`).

### Starting a Simulation from the Dashboard

1. Click "New Sim" in the sidebar.
2. Choose a domain from the "Domain Protocol" dropdown.
3. Configure domain-specific options (player count, model assignments, map preset, etc.).
4. Click "INITIALIZE". The sim starts immediately and its entry appears in the sidebar.
5. Click a sim entry to open the detail view, which shows the domain board, event log, agent strategy (plan history), and data banks (memory files).
6. For Werewolf sims, share `/watch/<sim_id>` for the public spectator page.

### Starting or Stopping Sims Remotely

With `LEMON_SIM_UI_ACCESS_TOKEN` configured, operators can manage sims over HTTP without exposing the admin dashboard publicly.

```bash
# Start a public werewolf broadcast
curl -X POST http://localhost:4090/api/admin/sims \
  -H 'authorization: Bearer YOUR_ADMIN_TOKEN' \
  -H 'content-type: application/json' \
  -d '{
    "domain": "werewolf",
    "sim_id": "ww_showmatch_001",
    "player_count": 6,
    "model_specs": [
      "google_gemini_cli:gemini-2.5-flash",
      "anthropic:claude-sonnet-4-20250514",
      "google_gemini_cli:gemini-2.5-flash",
      "openai-codex:gpt-5.3-codex-spark",
      "google_gemini_cli:gemini-2.5-flash",
      "anthropic:claude-sonnet-4-20250514"
    ]
  }'

# Stop a sim
curl -X POST http://localhost:4090/api/admin/sims/ww_showmatch_001/stop \
  -H 'authorization: Bearer YOUR_ADMIN_TOKEN'
```

The create response includes the private admin URL and, for werewolf, the public `watch_url`.

## Production Deployment

### Required environment

| Variable | Purpose |
|---|---|
| `PHX_SERVER=true` | Starts the Phoenix endpoint in release/container mode |
| `LEMON_SIM_UI_SECRET_KEY_BASE` | Phoenix secret key base for `lemon_sim_ui` |
| `LEMON_SIM_UI_HOST` | Public hostname for generated links |
| `LEMON_SIM_UI_PORT` | HTTP bind port (defaults to `4090`) |
| `LEMON_SIM_UI_ACCESS_TOKEN` | Protects admin dashboard + admin API |
| `LEMON_STORE_PATH` | Persistent SQLite path or directory for sim state |
| `LEMON_SECRETS_MASTER_KEY` | Required on servers/containers that cannot read your local keychain but still need encrypted Lemon secrets |

You will also need the provider credentials used by your chosen sim models (for example `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or Google/Gemini credentials).

### Release build

```bash
MIX_ENV=prod mix release sim_broadcast_platform
./_build/prod/rel/sim_broadcast_platform/bin/sim_broadcast_platform start
```

### Docker build

Build from the repository root:

```bash
docker build -f apps/lemon_sim_ui/Dockerfile -t lemon-sim-broadcast .

docker run --rm -p 4090:4090 \
  -e PHX_SERVER=true \
  -e LEMON_SIM_UI_HOST=sim.example.com \
  -e LEMON_SIM_UI_PORT=4090 \
  -e LEMON_SIM_UI_SECRET_KEY_BASE=replace_me \
  -e LEMON_SIM_UI_ACCESS_TOKEN=replace_me \
  -e LEMON_STORE_PATH=/data/store \
  -v $(pwd)/.data/lemon-sim:/data \
  lemon-sim-broadcast
```

For internet exposure, put the container/release behind a TLS reverse proxy and publish only the `lemon_sim_ui` port.

### Starting a Simulation Programmatically

```elixir
# Start a Werewolf sim with specific models for each seat
{:ok, sim_id} = LemonSimUi.SimManager.start_sim(:werewolf, [
  player_count: 6,
  model_specs: [
    "google_gemini_cli:gemini-3-flash-preview",
    "anthropic:claude-sonnet-4-20250514",
    "google_gemini_cli:gemini-2.5-flash",
    "openai-codex:gpt-5.3-codex-spark",
    "google_gemini_cli:gemini-3-pro-preview",
    "deepseek:deepseek-chat"
  ]
])

# Check running sims
running = LemonSimUi.SimManager.list_running()

# Stop a sim
:ok = LemonSimUi.SimManager.stop_sim(sim_id)
```

### Watching a Sim Without the Browser

The `LemonSim.Store` and `LemonSim.Bus` are accessible directly from IEx:

```elixir
# Read current state
state = LemonSim.Store.get_state(sim_id)

# Subscribe to updates
LemonSim.Bus.subscribe(sim_id)
# => receives %LemonCore.Event{type: :sim_world_updated, ...}
```

## Testing

```bash
mix test apps/lemon_sim_ui
```

Tests use `LemonSimUi.ConnCase` backed by `Phoenix.ConnTest` and `Phoenix.LiveViewTest`. The test suite covers:

- Dashboard mount with no sims (empty state rendering)
- Sim list display when a state exists in the store
- Navigation from lobby to sim detail via `render_patch/2`
- Board component rendering for each domain

Individual test files:

```bash
mix test apps/lemon_sim_ui/test/lemon_sim_ui/live/sim_dashboard_live_test.exs
mix test apps/lemon_sim_ui/test/lemon_sim_ui/live/components/board_components_test.exs
mix test apps/lemon_sim_ui/test/lemon_sim_ui/access_control_test.exs
mix test apps/lemon_sim_ui/test/lemon_sim_ui/admin_sim_controller_test.exs
```
