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
  |-- LemonSimUi.Arena              GenServer per domain: always-on league scheduler
  |-- LemonSimUi.HostedGame         Durable hosted Werewolf room coordinator
  |-- LemonSimUi.HostedGame.RoomServer  One serialized runtime per hosted room
  |-- LemonSimUi.ArenaDomains       Presentation config for arena domains
  |-- LemonSimUi.LobbyLive          Public live-games landing page
  |-- LemonSimUi.LeaderboardLive    Public benchmark suite leaderboard page
  |-- LemonSimUi.ArenaLive          Stable "watch the live game" entry per domain
  |-- LemonSimUi.ArenaLeaderboardLive     Public league standings per domain
  |-- LemonSimUi.SimDashboardLive   Admin LiveView for sim launch and detail
  |-- LemonSimUi.SpectatorLive      Public read-only spectator LiveView
  |-- LemonSimUi.Hosted*Live        Host, player, join, and role-safe room views
  |-- LemonSimUi.ArtifactReader     Reads suite and usage JSON artifacts
  |-- LemonSimUi.SimHelpers         Pure helpers: domain inference, labels, colors
  |-- LemonSimUi.Live.Components.*  Stateless function components per domain board
  |-- LemonSimUi.Endpoint           Bandit-backed Phoenix endpoint
  |-- assets/                       Locked Tailwind/esbuild source and browser dependencies
```

`SimManager` owns the runner lifecycle for active sims. It runs tasks under a dedicated supervisor, writes lifecycle/RNG checkpoints after each step, resumes supported games after runner or service restarts, and publishes `LemonCore.Bus` events so LiveView receives push updates without polling. Boot recovery keeps retrying through store outages; transient resume failures use bounded exponential backoff and are durably marked failed if exhausted. Final token, cost-availability, and model-call latency usage is persisted before a runner's collector is stopped and restored into resumed collectors, so league accounting survives process and service restarts. Operator stops and arena abandonment are durable, and `LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS` queues persisted recovery instead of allowing an unbounded model-call fanout. For Werewolf specifically, push updates carry the exact state snapshot that changed, which lets the UI buffer fast backend turns and play them back at a readable pace instead of skipping straight to the latest phase.

The LiveView transport is websocket-only. `LemonSimUi.Endpoint` disables the `/live/longpoll` transport, and the browser client connects without enabling a long-poll fallback.

`SimDashboardLive` subscribes to two topics:

- `SimManager.lobby_topic/0` — for sim list changes (start, stop, finish)
- `LemonSim.Kernel.Bus` topic for the currently viewed sim — for per-step world updates

Public routes are served separately from admin routes. `LobbyLive` handles `/` as a Werewolf-first broadcast lobby: it promotes the current match with day, phase, alive count, and public model lineup; falls back to a stable arena intermission; and lists every live or artifact-backed public broadcast with a direct watch link. `LeaderboardLive` serves `/leaderboards`, `SpectatorLive` serves `/watch/:sim_id`, hosted Werewolf begins at `/play`, `AdminSessionController` handles `/admin/login` and `/admin/logout`, and `SimDashboardLive` handles the authenticated control room at `/admin` and `/admin/sims/:sim_id`. The leaderboard page scans configured `:suite_roots` for LemonSim `suite.json` files, skips malformed files with a log line, and renders verified rankings, mean/std/n statistics when present, failures, token totals, and null-safe costs. For CLI-driven VendingBench runs, the lobby and spectator route can fall back to checkpoint artifacts registered by the runner and refresh from `final_world.json` while the run is in progress. The spectator route renders total and per-actor usage/cost from a live UI-managed usage collector when present, otherwise from checkpoint `usage.json`, without treating unknown cost as zero. The VendingBench board shows the active operator and physical-worker model labels when the checkpoint world includes runtime model metadata, and Arena worlds render multi-agent standings, messages, payments, trades, supplier leads, price-war signals, and collusion flags above the vending-machine broadcast. TCG Shop sims are also watchable through the public spectator route using the same read-only board as the admin dashboard.

On the model-arena Werewolf board, the current day's public discussion transcript remains visible until it is archived into day history, and the most recent archived day opens expanded by default. The admin detail and model-broadcast watcher share that full-story surface, including model wolf chat, meetings, journals, and generated lore. Hosted human rooms never reuse this omniscient board: they use dedicated player and public projections so roles, night actors, votes, pack chat, investigations, meetings, items, and journals are only delivered to an entitled session.

Admin surfaces are private and fail closed. Production startup fails unless `LEMON_SIM_UI_ACCESS_TOKEN` is at least 32 bytes, and development also requires a configured token before the control room can be opened. Browsers enter the token through the CSRF-protected `/admin/login` form; the raw token is never accepted from a URL or stored in the cookie. A signed digest marker authenticates `/admin` and `/admin/sims/:sim_id` for eight hours by default, logout deletes it, and rotating the deployment token invalidates every existing admin session. JSON `/api/admin/*` routes remain stateless and accept only `Authorization: Bearer` credentials, never browser cookies or query parameters. All admin and login responses are `private, no-store`. The public lobby (`/`), leaderboard route (`/leaderboards`), spectator route (`/watch/:sim_id`), liveness route (`/healthz`), and readiness route (`/readyz`) remain public. The control-room overview shows the active Werewolf broadcast, automation owner, running/stored counts, and recent simulations; the detail view links to a separate public watch page without adding operator controls to it. If `LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER=true`, the public lobby shows the configured VendingBench launcher presets. Presets come from `config :lemon_sim_ui, :vending_launcher_presets`; malformed entries are logged and skipped, and the default presets are GLM 5.1 on Z.AI and GPT 5.5 on Codex OAuth. Public pages publish a Werewolf-specific Open Graph/X share card from `priv/static/assets/werewolf/og-live.png`.

### Hosted Werewolf rooms

Hosted Werewolf is a separate durable multiplayer path:

- `/play` creates a room or accepts a 10-character join code; `/join/:code` claims a human seat.
- `/rooms/:id/host` is the role-blind host console, `/rooms/:id/play` is one private player seat, and `/rooms/:id/watch` is a public-safe story only when the room was created with public visibility.
- Roles stay sealed until the match starts, and lobby or pre-start cancellation views show only a waiting state. Secret-phase actor identity is hidden from hosts, the public, and players outside the entitled pack, night action, or meeting cohort. All roles are revealed to players and spectators after completion.
- Host and player credentials are random 256-bit tokens. Only SHA-256 hashes are stored; raw tokens live in signed, HTTP-only, SameSite cookies with a 30-day lifetime and transient LiveView private state, not assigns or logs. A browser retains at most eight recent room credentials.
- The host can start, pause, replace a seat while paused, resume, stop, cancel, export a completed replay, and prepare a rematch. Timers and RNG state survive process/service restarts. Persisted deadlines reject late human and AI actions, commands include match and state epochs, and accepted actions are idempotently built into authoritative events on the server.
- `story` rules enable meetings, village events, evidence, items, and wandering. `classic` keeps roles, night actions, discussion, and voting only.
- The Seer investigates on Night 1. Exact starting/remaining role counts and timestamped public role reveals are part of every player projection. Backstory connections are role-independent flavor.
- Meeting preferences travel with each Night action: mutual requests resolve first, then non-conflicting directed requests, with no extra selection phase. Doctors cannot repeat a protection target on consecutive nights. Evidence names two possible sources, cannot stack with a positive wander sighting from the same night, and remains a calibrated noisy lead rather than a Doctor/Seer-action artifact. A prevented attack does not reveal its target.
- Arena rotations advance on every attempt. Failed attempts are retained as reliability data and shown as per-model completion rates without changing ratings from completed games.
- Replay exports contain canonical redacted events and state hashes and can be checked with `LemonSimUi.HostedGame.Replay.verify/1`. Provider randomness is isolated from authoritative updater RNG. Human private notes are not accepted; model thoughts are redacted.
- Hosted room recovery, pending terminal writes, bounded AI work, room counts, provider latency, phase duration, actions, reconnects, timeouts, and failures are exposed through protected `/api/admin/metrics`. `/readyz` stays unavailable until room recovery and pending terminal writes are complete.

Hosted rooms are single-node while persistence is local SQLite and PubSub is local. Run exactly one application instance unless room ownership, storage, and PubSub are moved to shared/distributed services.

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
| VendingBench | `:vending_bench` | Watchable nested-agent vending operation and Vending-Bench Arena worlds with model labels, standings, supplier inbox/outbox, deliveries, refunds, machine faults, PvP messages/payments/trades/leads, price wars, collusion signals, and scorecard signals |
| TCG Shop | `:tcg_shop` | Single-operator local game store with sealed allocations/openings, loose-pack prep/sell-through, special orders/holds, supplier credit and standing, damaged-delivery supplier claims, financing, register cash/card tenders, bank deposits, drawer reconciliation, local returns/store-credit refunds, buylist store credit, consignment payables, memberships, preorders, promotion campaigns, collection buys, singles, grading, organized-play capacity/prize support, inventory aging, online orders, marketplace channel/listing fees, market pulses, tax ledger, COGS/gross margin, fixed overhead, operating profit, refunds, channel costs, payroll, scheduled staffing, local competition, loss prevention, shrinkage, and scorecard signals |
| Poker | `:poker` | Multi-seat poker engine and always-on league broadcast |

### Multi-Model Assignment

For social-deduction and multi-player domains (Werewolf, Stock Market, Survivor, Space Station), each player seat can be assigned a distinct model from the launch form. `SimManager` builds a `model_assignments` map keyed by the domain's canonical actor ID and uses an `on_before_step` callback to switch the active model before each turn. For Werewolf, those IDs are villager names (`"Alice"`, `"Bram"`, etc.), not `player_n` seat labels. All provider credentials are resolved through `LemonSim.GameHelpers.Config`.

Werewolf renders any `character_profiles` supplied in the initial world. Live
runs do not mutate persisted snapshots from a detached lore task; traits and
backstory connections remain the safe default characterization surface.

### Always-on model arenas (league broadcasts)

`LemonSimUi.Arena` runs one supervised scheduler per domain — werewolf, space_station, stock_market, survivor, and poker — each keeping a league game running at all times and turning every finished game into standings:

- General arenas sample a seeded model lineup via `LemonSim.Bench.League.plan_match/2`. Werewolf instead rotates the configured lineup one seat per recorded game against fixed sorted-seat roles, giving every model every role over a full cycle; the seed still reproduces game randomness.
- Finished games are recorded through the domain's `LemonSim.Bench.League.Registry` adapter into a file-backed league (`games/<sim_id>.json`, aggregated `league.json` + `league.md`) with per-model — and for team games per-role — standings, role-adjusted win rate, role-execution value, and Bradley-Terry ratings. Ratings remain marked provisional until every model covers every role.
- Crashed games are resumed via `SimManager.resume_sim/1` with backoff, then durably abandoned and replaced. On service restart, terminal games without a durable league marker are recorded before a new game starts; failed league writes and marker writes retry, and a watchdog tick guarantees an arena never stays dark.
- League standings use a configurable rolling record window (`LEMON_ARENA_<DOMAIN>_MAX_GAME_RECORDS`, default `1000`) so disk and recomputation costs remain bounded.
- `/arena/:domain` is the stable public URL per domain: it redirects to the live game (and the spectator page auto-advances between games), so it is safe to embed or point a stream at. `/arena/:domain/leaderboard` renders the league standings and live-updates on the `arena:<domain>:league` topic. `/werewolf` remains as a legacy alias.

Enable a domain by setting `LEMON_ARENA_<DOMAIN>_MODELS` (e.g. `LEMON_ARENA_SPACE_STATION_MODELS`) to a comma-separated list of `provider:model` specs with configured credentials; `WEREWOLF_ARENA_*` env vars remain as werewolf aliases. Do not combine with `LEMON_SIM_AUTO_LOOP` for the same domain — the auto-loop's single-model games would pollute that league.

### Interactive Mode

For Tic Tac Toe and Skirmish, the user can select a team at launch. On human turns:

- The runner process blocks in `receive` waiting for `{:human_move, event}`.
- The LiveView captures click events on the board and calls `SimManager.submit_human_move/2`.
- The `SimManager` forwards the event as a message to the runner process.
- Human turns time out after 5 minutes.

## Module Inventory

| Module | File | Purpose |
|---|---|---|
| `LemonSimUi.Application` | `lib/lemon_sim_ui/application.ex` | Starts telemetry, simulation runners, hosted-room supervision, arenas, and the endpoint |
| `LemonSimUi.LobbyLive` | `lib/lemon_sim_ui/live/lobby_live.ex` | Werewolf-first public broadcast lobby with featured match/intermission state, live watch links, arena navigation, and optional VendingBench launcher |
| `LemonSimUi.LeaderboardLive` | `lib/lemon_sim_ui/live/leaderboard_live.ex` | Public leaderboard page for benchmark suite artifacts under configured `:suite_roots` |
| `LemonSimUi.SimManager` | `lib/lemon_sim_ui/sim_manager.ex` | GenServer: lifecycle and runner loop for all active sims |
| `LemonSimUi.SimDashboardLive` | `lib/lemon_sim_ui/live/sim_dashboard_live.ex` | Protected operator control room for Werewolf broadcast status, launch/automation actions, recent runs, and full sim detail flows |
| `LemonSimUi.SpectatorLive` | `lib/lemon_sim_ui/live/spectator_live.ex` | Public shareable watcher for Werewolf, VendingBench, and TCG Shop with no admin controls; shows live usage collector snapshots or artifact `usage.json` |
| `LemonSimUi.HostedGame` | `lib/lemon_sim_ui/hosted_game.ex` | Hosted-room creation, join-code reservation, recovery/readiness, capacity, retention, and kill-switch coordinator |
| `LemonSimUi.HostedGame.Supervisor` | `lib/lemon_sim_ui/hosted_game/supervisor.ex` | One-for-all boundary for room registry, room supervisor, bounded AI tasks, and recovery coordinator |
| `LemonSimUi.HostedGame.RoomServer` | `lib/lemon_sim_ui/hosted_game/room_server.ex` | Durable serialized room lifecycle, authorization, timers, AI/human commands, projections, reconnects, replay, and rematches |
| `LemonSimUi.HostedGame.Replay` | `lib/lemon_sim_ui/hosted_game/replay.ex` | Replays canonical redacted events and verifies per-command/final state hashes |
| `LemonSimUi.HostedLobbyLive`, `HostedJoinLive`, `HostedHostLive`, `HostedPlayerLive`, `HostedWatchLive` | `lib/lemon_sim_ui/live/hosted_werewolf_live.ex` | Responsive hosted room creation, joining, role-blind host control, private player action, and public-safe viewing |
| `LemonSimUi.HostedGameSessionController` | `lib/lemon_sim_ui/controllers/hosted_game_session_controller.ex` | Validates hosted forms, exchanges tokens into bounded signed sessions, and downloads replay exports |
| `LemonSimUi.AdminSessionController` | `lib/lemon_sim_ui/controllers/admin_session_controller.ex` | CSRF-protected admin login/logout, safe return-to handling, and signed-session renewal |
| `LemonSimUi.MetricsController` | `lib/lemon_sim_ui/controllers/metrics_controller.ex` | Protected aggregate runtime/room/arena metrics without credentials or raw provider errors |
| `LemonSimUi.ArtifactReader` | `lib/lemon_sim_ui/artifact_reader.ex` | Reads `suite.json` and `usage.json`, formats null-safe cost and token totals |
| `LemonSimUi.WerewolfPlayback` | `lib/lemon_sim_ui/werewolf_playback.ex` | Buffers exact Werewolf snapshots and applies dwell heuristics so live viewing stays legible |
| `LemonSimUi.AdminSimController` | `lib/lemon_sim_ui/controllers/admin_sim_controller.ex` | Protected JSON API for starting and stopping sims remotely |
| `LemonSimUi.HealthController` | `lib/lemon_sim_ui/controllers/health_controller.ex` | Public liveness and dependency readiness checks used by load balancers and smoke tests |
| `LemonSimUi.SimHelpers` | `lib/lemon_sim_ui/sim_helpers.ex` | Domain type inference, status labels, badge colors, world summaries |
| `LemonSimUi.Live.Components.EventLog` | `lib/lemon_sim_ui/live/components/event_log.ex` | Renders `recent_events` with per-kind color coding |
| `LemonSimUi.Live.Components.PlanHistory` | `lib/lemon_sim_ui/live/components/plan_history.ex` | Renders `plan_history` steps with summary and rationale |
| `LemonSimUi.Live.Components.RunLog` | `lib/lemon_sim_ui/live/components/run_log.ex` | Renders current run status, recent events, and model-visible tool/decision traces |
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
| `LemonSimUi.Live.Components.VendingBenchBoard` | `lib/lemon_sim_ui/live/components/vending_bench_board.ex` | Retro vending-machine broadcast view with generated product sprites, Arena standings, supplier delivery, refund, machine fault, PvP payment/trade/lead/price-war/collusion, and scorecard display |
| `LemonSimUi.Live.Components.TcgShopBoard` | `lib/lemon_sim_ui/live/components/tcg_shop_board.ex` | TCG Shop dashboard for sealed inventory/openings, loose-pack inventory and sales, special-order deposits/fulfillment, supplier credit/accounts payable, damaged-delivery claims, supplier standing, financing, register cash/card tenders, bank deposits, drawer reconciliation, local returns/store-credit refunds, store credit, consignment payables, memberships, preorders, promotions, organized-play capacity/prize support, inventory aging, singles, graded-card lots, grading risk, market pulse, online marketplace channel/listing fees, tax ledger, gross margin, fixed overhead, operating profit, refunds, channel costs, payroll, scheduled staffing, loss prevention, local competition, customer loyalty/satisfaction, staff hours, supplier fill rate, stockouts, shrinkage, backorders, and scorecard display |
| `LemonSimUi.Router` | `lib/lemon_sim_ui/router.ex` | Splits public, no-store hosted, protected browser, and protected JSON routes |
| `LemonSimUi.Endpoint` | `lib/lemon_sim_ui/endpoint.ex` | Bandit HTTP server, LiveView socket, static asset serving |
| `LemonSimUi.CoreComponents` | `lib/lemon_sim_ui/components/core_components.ex` | Phoenix-generated shared form/flash/button components |

## Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| `lemon_core` | Umbrella | `LemonCore.Bus` for pubsub, `LemonCore.Store` via `LemonSim.Kernel.Store`, config helpers |
| `lemon_sim` | Umbrella | `Runner`, `Store`, `Bus`, all domain examples and `GameHelpers` |
| `phoenix` | Hex (~> 1.7) | HTTP and LiveView framework |
| `phoenix_html` | Hex (~> 4.1) | HTML helpers |
| `phoenix_live_view` | Hex (~> 1.0) | Server-rendered real-time UI |
| `phoenix_live_reload` | Hex (~> 1.5, dev only) | Hot code reloading in development |
| `gettext` | Hex (~> 0.26) | Internationalisation support |
| `jason` | Hex (~> 1.4) | JSON encoding/decoding |
| `bandit` | Hex (~> 1.5) | HTTP server (replaces Cowboy) |
| `lazy_html` | Hex (~> 0.1, test only) | HTML parsing in LiveView tests |

## Usage

Install and build the version-locked local browser assets after cloning or when
HEEx/CSS/JS changes:

```bash
mix sim_ui.assets.setup
mix sim_ui.assets.build
```

The generated `priv/static/assets/app.css` and `app.js` are packaged with the
OTP release. The deployed UI does not load Tailwind, fonts, Phoenix, or
LiveView from third-party CDNs.
`mix sim_ui.assets.deploy` also fails on high-severity npm advisories before it
digests the production assets.
The release smoke lane runs `npm run smoke:werewolf` against the production
container with system Chrome. It verifies a connected LiveView WebSocket, a
server-driven DOM patch, keyboard entry, mobile content order, and horizontal
overflow at 320, 390, and 1440 pixels.
`npm run smoke:hosted-werewolf` runs the hosted multiplayer lane against
`HOSTED_WEREWOLF_SMOKE_URL`: five isolated browser sessions, role sealing,
pack-chat non-leakage, a real timeout, pause/resume, reload reconnect, full
completion, replay download, rematch, reduced motion, keyboard focus, and
375x812, 768x1024, and 1440x900 layouts.

The app starts automatically as part of the umbrella. To start the umbrella in development:

```bash
mix phx.server
# or
iex -S mix phx.server
```

The public lobby is available at `http://localhost:4090/`, hosted Werewolf at `http://localhost:4090/play`, public suite leaderboards at `http://localhost:4090/leaderboards`, and the admin dashboard at `http://localhost:4090/admin` (port configured in `config/dev.exs`). Configure `LEMON_SIM_UI_ACCESS_TOKEN` before opening `/admin`; unauthenticated browsers are redirected to `/admin/login`, where the token is submitted as a CSRF-protected form body rather than a query parameter. Set `LEMON_SIM_UI_BIND_IP=0.0.0.0` to bind the development server on all interfaces, for example when browsing over Tailscale, but only expose admin over HTTPS. Set `LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER=true` to expose the lobby VendingBench launcher.

Configure benchmark suite discovery with `config :lemon_sim_ui, :suite_roots, ["/tmp/vending-suite"]`. Each root may be a suite directory containing `suite.json` directly or a parent directory containing one suite per child directory.

### Starting a Simulation from the Dashboard

1. Open `/admin` and click "Launch match" in the sidebar or "Launch Werewolf match" in the control-room header.
2. Choose a domain from the "Domain Protocol" dropdown.
3. Configure domain-specific options (player count, model assignments, map preset, etc.).
4. Click "INITIALIZE". The sim starts immediately and its entry appears in the sidebar and control-room history.
5. Click a sim entry to open the detail view, which shows the domain board, event log, agent strategy (plan history), and data banks (memory files).
6. For Werewolf, VendingBench, and TCG Shop sims, use "Public view" in the detail header or share `/watch/<sim_id>` for the spectator page.

### Auto-Loop Operations

The admin control room can enable or disable auto-looping for supported domains. Auto-loop is currently used for continuously restarting Werewolf broadcasts after a completed game. When the supervised Werewolf arena is enabled, the control room reports it as the broadcast owner and disables the overlapping auto-loop toggle.

For deployment-driven auto-loop startup, set:

- `LEMON_SIM_AUTO_LOOP=true`
- `LEMON_SIM_WEREWOLF_PLAYERS=<count>` to override the default of `6`

These runtime flags are operational concerns. They belong with deployment config such as [fly.toml](./fly.toml), not with the core public/admin route split.
A disabled Werewolf arena configuration may coexist with auto-loop; an enabled
Werewolf arena may not, because both would own the same broadcast domain.

### Starting or Stopping Sims Remotely

With `LEMON_SIM_UI_ACCESS_TOKEN` configured, operators can manage sims over HTTP without using the browser session. API authentication is bearer-only:

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
      "openai:gpt-5.2",
      "anthropic:claude-sonnet-4-20250514",
      "google:gemini-2.5-flash",
      "openai:gpt-5.2",
      "google:gemini-2.5-flash",
      "anthropic:claude-sonnet-4-20250514"
    ]
  }'

# Stop a sim
curl -X POST http://localhost:4090/api/admin/sims/ww_showmatch_001/stop \
  -H 'authorization: Bearer YOUR_ADMIN_TOKEN'
```

The create response includes the private admin URL and, for Werewolf, VendingBench, and TCG Shop, the public `watch_url`.

## Production Deployment

### Required environment

| Variable | Purpose |
|---|---|
| `PHX_SERVER=true` | Starts the Phoenix endpoint in release/container mode |
| `LEMON_SIM_UI_SECRET_KEY_BASE` | Required in production; Phoenix secret key base with at least 64 bytes |
| `LEMON_SIM_UI_HOST` | Required in production; public hostname without scheme/path |
| `LEMON_SIM_UI_PORT` | HTTP bind port (defaults to `4090`) |
| `LEMON_SIM_UI_URL_SCHEME` | Public URL scheme (`https` by default). Production hosted rooms require `https`; direct HTTP is only supported when hosted rooms are disabled |
| `LEMON_SIM_UI_URL_PORT` | Public URL port (defaults to `443` for HTTPS or `80` for HTTP) |
| `LEMON_SIM_UI_BIND_IP` | Development bind address; use `0.0.0.0` for LAN/Tailscale access |
| `LEMON_SIM_UI_ACCESS_TOKEN` | Required in production; at least 32 bytes; protects admin dashboard + admin API |
| `LEMON_SIM_UI_ADMIN_SESSION_TTL_SECONDS` | Browser admin-session lifetime, from `300` to `86400` seconds (default `28800`, eight hours) |
| `LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS` | Maximum active model runners per instance (default `8`); queued recoveries wait for capacity |
| `LEMON_SIM_UI_MAX_STORED_SIMS` | Maximum terminal snapshots retained (default `500`); active/recoverable games are never pruned |
| `LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER` | Enables the public lobby's fixed VendingBench launch form |
| `LEMON_WEREWOLF_HOSTED_ENABLED` | Enables hosted rooms (defaults to `false` in production and `true` in dev/test); disabled boot does not recover timers or AI tasks |
| `LEMON_WEREWOLF_HOST_CREATE_TOKEN` | Required when hosted rooms are enabled in production; at least 32 bytes; authorizes room creation |
| `LEMON_WEREWOLF_HOSTED_ROOM_LIMIT` | Maximum simultaneously active hosted rooms (default `100`, maximum `500`) |
| `LEMON_WEREWOLF_HOSTED_ROOM_RETENTION` | Maximum retained completed/stopped room records (default `500`, maximum `5000`) |
| `LEMON_WEREWOLF_HOSTED_LOBBY_TTL_SECONDS` | Abandoned lobby lifetime before pruning (default `86400`; range 300–2592000) |
| `LEMON_WEREWOLF_HOSTED_INACTIVE_TTL_SECONDS` | Paused-room lifetime before pruning (default `604800`; range 3600–31536000) |
| `LEMON_WEREWOLF_HOSTED_AI_MODEL` | Frozen `provider:model` used by newly created AI seats; provider credentials are validated before AI rooms start |
| `LEMON_WEREWOLF_HOSTED_AI_CONCURRENCY` | Global hosted AI provider-call cap per instance (default `4`, range 1–64) |
| `LEMON_STORE_PATH` | Required absolute path in production; persistent SQLite path or directory for sim state |
| `LEMON_SECRETS_MASTER_KEY` | Required on servers/containers that cannot read your local keychain but still need encrypted Lemon secrets |
| `LEMON_SIM_AUTO_LOOP` | When `true`, boot configured auto-loop simulations on startup |
| `LEMON_SIM_WEREWOLF_PLAYERS` | Player count for boot-time Werewolf auto-loop (defaults to `6`) |
| `LEMON_ARENA_<DOMAIN>_MODELS` | Comma-separated `provider:model` pool; setting this enables that domain's always-on arena (domains: `WEREWOLF`, `SPACE_STATION`, `STOCK_MARKET`, `SURVIVOR`) |
| `LEMON_ARENA_<DOMAIN>_ENABLED` | Set `0`/`false` to keep a configured arena off (defaults to on) |
| `LEMON_ARENA_<DOMAIN>_PLAYER_COUNT` | Seats per league game (defaults: werewolf/space_station 6, stock_market 4, survivor 8) |
| `LEMON_ARENA_<DOMAIN>_GAME_DELAY_MS` | Intermission between games (defaults to `15000`) |
| `LEMON_ARENA_<DOMAIN>_MAX_GAME_RECORDS` | Rolling league record/standings window (default `1000`) |
| `LEMON_ARENA_<DOMAIN>_LEAGUE_DIR` | League records/standings dir for one domain |
| `LEMON_ARENA_LEAGUE_ROOT` | Root dir for all leagues (`<root>/<domain>_league`; `/app/data/leagues` in the container) |
| `WEREWOLF_ARENA_*`, `WEREWOLF_LEAGUE_DIR` | Legacy aliases for the werewolf arena's `LEMON_ARENA_WEREWOLF_*` equivalents |

You will also need the provider credentials used by your chosen sim models (for example `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or Google/Gemini credentials).

### Public VendingBench launcher presets

The public launcher stays disabled unless `:public_vending_launcher` is true. Configure its cards with:

```elixir
config :lemon_sim_ui, :vending_launcher_presets, [
  %{
    id: "zai_glm_5_1",
    label: "GLM 5.1",
    model: "zai:glm-5.1",
    worker_model: "zai:glm-5.1",
    max_days: 30,
    max_turns: 300
  },
  %{
    id: "codex_gpt_5_5",
    label: "GPT 5.5",
    model: "openai-codex:gpt-5.5",
    worker_model: "openai-codex:gpt-5.5",
    max_days: 30,
    max_turns: 300
  }
]
```

Unset config uses the two presets above. Invalid entries are logged and skipped so the public lobby remains available.

### Release build

```bash
MIX_ENV=prod mix sim_ui.assets.deploy
MIX_ENV=prod mix release sim_broadcast_platform
set -a
. apps/lemon_sim_ui/.env.example
set +a
./_build/prod/rel/sim_broadcast_platform/bin/sim_broadcast_platform start
```

Copy [`.env.example`](./.env.example) to a private deployment env file, replace
every placeholder, create the configured host directories, and source that
private file before booting the release. The checked-in credentials are
deliberately too short to pass production validation.

### Docker build

Build from the repository root:

```bash
docker build \
  --build-arg "LEMON_GIT_SHA=$(git rev-parse HEAD)" \
  -f apps/lemon_sim_ui/Dockerfile \
  -t lemon-sim-broadcast .

docker run --rm -p 4090:4090 \
  -e PHX_SERVER=true \
  -e LEMON_SIM_UI_HOST=sim.example.com \
  -e LEMON_SIM_UI_PORT=4090 \
  -e LEMON_SIM_UI_URL_SCHEME=https \
  -e LEMON_SIM_UI_URL_PORT=443 \
  -e "LEMON_SIM_UI_SECRET_KEY_BASE=$(openssl rand -base64 64)" \
  -e "LEMON_SIM_UI_ACCESS_TOKEN=$(openssl rand -base64 48)" \
  -v "$(pwd)/.data/lemon-sim:/app/data" \
  lemon-sim-broadcast
```

The container runs the BEAM as UID/GID `10001`, stores SQLite state under
`/app/data/store`, stores league artifacts under `/app/data/leagues`, and uses
`/readyz` for its Docker health check. Mount `/app/data` for every deployment.
The root entrypoint repairs ownership under `/app/data/store` and
`/app/data/leagues` before dropping privileges, including volumes and restores
created by older images. Release code remains root-owned and read-only to the
runtime process; the volume root stays root-owned so the app cannot alter
off-instance backup material mounted alongside those writable trees.
The builder copies only `ai`, `agent_core`, `lemon_core`, `lemon_sim`, and
`lemon_sim_ui`, which keeps unrelated umbrella applications and dependencies
out of the image.

### Fly.io

This is a single-Machine deployment while state uses local SQLite and PubSub.
Create the persistent volume, keep the app at one Machine, configure secrets,
then deploy from the repository root:

```bash
fly volumes create lemonsim_data --app lemonsim --region sjc --size 1 --snapshot-retention 14
fly scale count 1 --app lemonsim
fly secrets set --app lemonsim \
  LEMON_SIM_UI_SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  LEMON_SIM_UI_ACCESS_TOKEN="$(openssl rand -base64 48)" \
  LEMON_WEREWOLF_HOST_CREATE_TOKEN="$(openssl rand -base64 48)"
fly secrets set --app lemonsim LEMON_WEREWOLF_HOSTED_ENABLED=true
fly deploy . --app lemonsim --config apps/lemon_sim_ui/fly.toml \
  --dockerfile apps/lemon_sim_ui/Dockerfile \
  --build-arg "LEMON_GIT_SHA=$(git rev-parse HEAD)"
```

Set `LEMON_WEREWOLF_HOSTED_AI_MODEL` plus its provider credential only when AI
seats are required. Set provider credentials and `LEMON_ARENA_WEREWOLF_MODELS`
when running the arena. Verify `https://lemonsim.fly.dev/healthz`, `/readyz`,
`/`, `/play`, room create/join/reconnect, and an unauthenticated `/admin`
response before directing traffic.

`/healthz` proves the HTTP process is alive. `/readyz` returns JSON and only
reports ready when SimManager, all arena supervisors, hosted recovery, pending
terminal room writes, and the non-mutating SQLite liveness query succeed; it
also reports build identity and runner capacity.

Backup, restore, path-migration, and rollback commands are in
[`docs/release/deployment_flows.md`](../../docs/release/deployment_flows.md#sim-broadcast-operations).

For internet exposure, put the container/release behind a TLS reverse proxy and publish only the `lemon_sim_ui` port.

### Live Run Log

The VendingBench public watcher renders a live run log below the board. It is driven by the same `State` updates as the board:

- board telemetry for financials, storage, sales mix, supplier ledger, pending deliveries, active failure modes, complaints, reminders, worker reports, arena standings, and PvP message/payment/trade/lead pressure
- current status from world fields such as day, phase, actor, bank balance, and runner errors
- recent domain events from `state.recent_events`, summarized as operations history for supplier orders, deliveries, sales, refunds, spoilage, stocking, pricing, Arena messages, Arena payments, Arena trades, supplier-lead shares, price-war signals, and collusion signals
- model-visible decision traces from `state.plan_history`
- decision-pressure signals inferred from visible world state, including rejected actions, pending deliveries, open reminders, stockouts, complaints, and runner errors

`SimManager` appends a compact trace after each successful model step. The trace includes tool names, selected arguments, tool results, and resulting event kinds. It does not expose provider-hidden chain-of-thought; only visible rationale or tool-call summaries returned through LemonSim are rendered.

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

The `LemonSim.Kernel.Store` and `LemonSim.Kernel.Bus` are accessible directly from IEx:

```elixir
# Read current state
state = LemonSim.Kernel.Store.get_state(sim_id)

# Subscribe to updates
LemonSim.Kernel.Bus.subscribe(sim_id)
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
- TCG Shop domain detection and board rendering for sealed inventory, singles,
  supplier credit, supplier standing, financing, register cash/card tenders, drawer reconciliation, local returns, sealed openings, consignment payables, memberships, preorders, promotions, organized-play capacity, market pulse, tax ledger, gross
  margin, fixed overhead, operating profit, refunds, channel costs, payroll, local competition, inventory aging, shrinkage, and
  customer queue

Individual test files:

```bash
mix test apps/lemon_sim_ui/test/lemon_sim_ui/live/sim_dashboard_live_test.exs
mix test apps/lemon_sim_ui/test/lemon_sim_ui/live/components/board_components_test.exs
mix test apps/lemon_sim_ui/test/lemon_sim_ui/access_control_test.exs
mix test apps/lemon_sim_ui/test/lemon_sim_ui/admin_sim_controller_test.exs
```
