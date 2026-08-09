# LemonSimUi Agent Guide

## Quick Orientation

`lemon_sim_ui` is a Phoenix LiveView dashboard for the `lemon_sim` simulation harness. It does not contain any simulation logic — all game rules, runners, and domain examples live in `lemon_sim`. This app is responsible for:

- launching, checkpointing, retrying/terminalizing recovery, and capacity-limiting simulations via `SimManager`
- driving the runner loop (calling `LemonSim.Kernel.Runner.step/3` in a supervised task)
- keeping the always-on model arenas running via `Arena` (one per domain: werewolf, space_station, stock_market, survivor, poker — randomized lineups, crash resume, restart reconciliation, and durably marked league recording through `LemonSim.Bench.League`)
- hosting durable human/AI Werewolf rooms via `HostedGame` and one serialized `RoomServer` per room
- rendering live state in the browser via the public `LobbyLive`, public `LeaderboardLive`, public `ArenaLive`/`ArenaLeaderboardLive` (per-domain arena + league standings), admin `SimDashboardLive`, and public read-only `SpectatorLive` watcher
- exposing a token-protected admin API for remote sim start/stop
- accepting human-player moves for interactive domains and server-authorized, match-epoch Werewolf commands

The primary entry points for model simulations are `SimManager`, `Arena`, `SimDashboardLive`, `SpectatorLive`, `LeaderboardLive`, and the board component for the relevant domain. Hosted Werewolf changes start in `HostedGame`, `HostedGame.RoomServer`, `HostedGame.Replay`, `HostedGameSessionController`, and `hosted_werewolf_live.ex`.

## File Structure

```
lib/
  lemon_sim_ui.ex                          Web context macros (router/live_view/html helpers)
  lemon_sim_ui/
    application.ex                         OTP application: supervisor tree
    endpoint.ex                            Bandit HTTP endpoint + LiveView socket
    router.ex                              Public, no-store hosted, private admin, and protected API routes
    artifact_reader.ex                     Suite/usage JSON readers and formatting helpers
    sim_manager.ex                         GenServer: owns all running sim tasks
    arena.ex                               GenServer per domain: always-on league scheduler + recorder
    arena_domains.ex                       Presentation config for arena domains
    hosted_game.ex                         Room creation, recovery, capacity, retention, kill switch
    hosted_game/
      supervisor.ex                        One-for-all hosted subsystem
      room_server.ex                       Durable room lifecycle, auth, timers, commands, replay
      replay.ex                            Canonical event replay/hash verifier
    philosopher_chat.ex                    PhilosopherChat thread coordinator + Thread struct
    philosopher_chat/
      supervisor.ex                        rest_for_one subsystem (Registry, ThreadSupervisor, AiTaskSupervisor, coordinator)
      thread_server.ex                     One durable serialized GenServer per thread: pacing loop, AI turns, broadcasts
      auth.ex                              Password login + 30-day Phoenix.Token bearer sessions, 60s SSE stream tickets, per-IP login rate limiting (ETS)
    sim_helpers.ex                         Pure helpers: domain inference, labels, colors
    werewolf_playback.ex                   Buffered live-playback helper for readable Werewolf spectator pacing
    telemetry.ex                           Bounded hosted lifecycle/latency metrics
    gettext.ex                             Gettext backend
    components/
      core_components.ex                   Shared form/button/flash components
      layouts.ex                           App/root layout modules
      layouts/app.html.heex
      layouts/root.html.heex
    controllers/
      admin_session_controller.ex          CSRF-protected admin login/logout + session renewal
      admin_sim_controller.ex              Token-protected JSON API for start/stop
      error_html.ex                        404/500 HTML error views
      error_json.ex                        JSON error views
      health_controller.ex                 Public liveness `/healthz` and dependency readiness `/readyz`
      hosted_game_session_controller.ex    Hosted form/session exchange and replay download
      metrics_controller.ex                Protected runtime metrics
      philosopher_chat_api_controller.ex   PhilosopherChat JSON API + SSE stream (`/api/chat/*`)
    live/
      lobby_live.ex                        Public list of currently running sims
      leaderboard_live.ex                  Public benchmark suite leaderboard page
      sim_dashboard_live.ex                Admin LiveView (launch + detail)
      spectator_live.ex                    Public read-only werewolf spectator view
      hosted_werewolf_live.ex              Hosted lobby/join/host/player/public-safe views
    plugs/
      require_access_token.ex              Expiring browser-session and bearer-only API gate
      require_chat_session.ex              Bearer-only gate for the PhilosopherChat API
      chat_cors.ex                         CORS for `/api/chat/*` (`LEMON_PHILOSOPHER_CHAT_CORS_ORIGINS`, default `*`) + OPTIONS preflight catch-all
      components/
        event_log.ex                       Renders recent_events list
        plan_history.ex                    Renders plan_history steps
        memory_viewer.ex                   Renders LemonSim.Memory.Tools files
        tic_tac_toe_board.ex               Board for :tic_tac_toe
        skirmish_board.ex                  Grid board for :skirmish (interactive)
        werewolf_board.ex                  Player cards for :werewolf
        stock_market_board.ex              Portfolio display for :stock_market
        survivor_board.ex                  Tribe/elimination for :survivor
        space_station_board.ex             Crew status for :space_station
        auction_board.ex                   Lot/bidder display for :auction
        diplomacy_board.ex                 Territory/faction display for :diplomacy
        dungeon_crawl_board.ex             Party/encounter display for :dungeon_crawl
        vending_bench_board.ex             Retro VendingBench machine view, generated product sprites, Arena standings, operations, supplier/fault signals, and scorecard display
        tcg_shop_board.ex                  Local game store view for TCG Shop finances, sealed inventory, sealed openings, loose-pack inventory/sales, special-order deposits/fulfillment, supplier credit, damaged-delivery claims, supplier standing, financing, register cash/card tenders, bank deposits, drawer reconciliation, local returns, store credit, consignment payables, memberships, preorders, promotions, organized-play capacity/prize support, inventory aging, singles, market pulse, online marketplace channels, tax ledger, gross margin, fixed overhead, operating profit, refunds, channel costs, payroll, scheduled staffing, loss prevention, local competition, shrinkage, customers, and scorecard
test/
  lemon_sim_ui/
    live/
      sim_dashboard_live_test.exs
      components/board_components_test.exs
  support/
    conn_case.ex
  test_helper.exs
```

Browser sources and locked npm dependencies live under `assets/`. Run
`mix sim_ui.assets.build` from the repository root after changing HEEx, CSS, or
JS. Release/container builds use `MIX_ENV=prod mix sim_ui.assets.deploy` to also
digest and precompress static files. Production pages must remain
self-contained and must not add runtime CDN dependencies.

## Key Modules

| File | Module | Purpose |
|---|---|---|
| `lib/lemon_sim_ui/sim_manager.ex` | `LemonSimUi.SimManager` | Central GenServer; durable start/stop/abandon/resume, RNG and final-usage checkpoints, bounded recovery queue with transient backoff/terminalization, retention, and auto-loop controls |
| `lib/lemon_sim_ui/hosted_game.ex` | `LemonSimUi.HostedGame` | Hosted room coordinator for codes, recovery readiness, active capacity, retention, and feature kill switch |
| `lib/lemon_sim_ui/hosted_game/room_server.ex` | `LemonSimUi.HostedGame.RoomServer` | One durable serialized room: token auth, safe projections, timers, AI/human commands, pause/replacement, export, and rematch |
| `lib/lemon_sim_ui/hosted_game/replay.ex` | `LemonSimUi.HostedGame.Replay` | Re-ingests redacted canonical events and checks command/final hashes |
| `lib/lemon_sim_ui/philosopher_chat.ex` | `LemonSimUi.PhilosopherChat` | PhilosopherChat coordinator: thread CRUD/validation, lazy restore, paused+closed retention pruning, per-thread memory roots |
| `lib/lemon_sim_ui/philosopher_chat/thread_server.ex` | `LemonSimUi.PhilosopherChat.ThreadServer` | One serialized GenServer per thread: paced agent turns (monitored AI tasks with hard timeout + bounded retries: exponential backoff, stall after 3 consecutive failures via `agent_stalled` broadcast), deferred reply for user messages posted mid-turn (`user_reply_pending`), live-state re-ingest so mid-turn user messages survive, single turn timer, persisted `pending_turn`/`rng_state`, idempotent `client_msg_id` posts, bounded broadcast log with `event_seq` cursor + restart-detecting `epoch` |
| `lib/lemon_sim_ui/philosopher_chat/auth.ex` | `LemonSimUi.PhilosopherChat.Auth` | `philosopher_chat_password` login (SHA-256 digest compare) and 30-day bearer tokens; 60s `stream_ticket`s so EventSource never puts the bearer in a URL; per-IP login bucket (5 attempts / 15 min, table owned by the chat supervisor); passwordless bypass when unconfigured outside prod |
| `lib/lemon_sim_ui/controllers/philosopher_chat_api_controller.ex` | `LemonSimUi.PhilosopherChatApiController` | Thin JSON API (`/api/chat/*`): rate-limited session, roster, `stream-ticket`, threads (validated bodies → 400), messages, nudge, pause/resume, memories, `events?since=` (`{events, epoch, latest_seq}`), and the SSE `stream` (verifies `?ticket=`/`?token=` itself because EventSource cannot set headers; replays missed events since the cursor before live streaming) |
| `lib/lemon_sim_ui/live/hosted_werewolf_live.ex` | `LemonSimUi.Hosted*Live` | Hosted room creation, joining, role-blind host, private player, and public-safe story surfaces |
| `lib/lemon_sim_ui/live/lobby_live.ex` | `LemonSimUi.LobbyLive` | Public lobby for `/`; lists running sims, links to spectator pages, and can expose configured VendingBench launcher presets |
| `lib/lemon_sim_ui/live/leaderboard_live.ex` | `LemonSimUi.LeaderboardLive` | Public leaderboard for `/leaderboards`; scans configured suite roots and renders rankings, failures, token totals, and null-safe costs |
| `lib/lemon_sim_ui/controllers/vending_bench_launch_controller.ex` | `LemonSimUi.VendingBenchLaunchController` | Public non-JS route for the fixed VendingBench launcher |
| `lib/lemon_sim_ui/live/sim_dashboard_live.ex` | `LemonSimUi.SimDashboardLive` | Dashboard LiveView for `/admin` and `/admin/sims/:sim_id`; handles sim launch and admin/detail flows |
| `lib/lemon_sim_ui/live/spectator_live.ex` | `LemonSimUi.SpectatorLive` | Public shareable watcher for `/watch/:sim_id`; supports Werewolf, VendingBench, and TCG Shop, subscribes to sim/lobby updates, refreshes CLI VendingBench runs from checkpoint artifacts, and shows live usage collector snapshots or artifact `usage.json` |
| `lib/lemon_sim_ui/artifact_reader.ex` | `LemonSimUi.ArtifactReader` | Reads `suite.json` and `usage.json`; keeps token/cost formatting null-safe |
| `lib/lemon_sim_ui/werewolf_playback.ex` | `LemonSimUi.WerewolfPlayback` | Buffers exact Werewolf state snapshots and enforces minimum dwell times so live dialogue/night beats stay readable |
| `lib/lemon_sim_ui/controllers/admin_sim_controller.ex` | `LemonSimUi.AdminSimController` | Protected JSON API for remote sim start/stop |
| `lib/lemon_sim_ui/controllers/admin_session_controller.ex` | `LemonSimUi.AdminSessionController` | CSRF-protected browser login/logout flow for the private control room |
| `lib/lemon_sim_ui/controllers/health_controller.ex` | `LemonSimUi.HealthController` | Public liveness and dependency readiness checks |
| `lib/lemon_sim_ui/plugs/require_access_token.ex` | `LemonSimUi.Plugs.RequireAccessToken` | Expiring signed-session gate for browsers and bearer-only gate for the admin API |
| `lib/lemon_sim_ui/sim_helpers.ex` | `LemonSimUi.SimHelpers` | `infer_domain_type/1`, `sim_summary/1`, `domain_label/1`, `domain_badge_color/1` |
| `lib/lemon_sim_ui/live/components/event_log.ex` | `LemonSimUi.Live.Components.EventLog` | Stateless component; renders `recent_events` with color-coded event kinds |
| `lib/lemon_sim_ui/live/components/plan_history.ex` | `LemonSimUi.Live.Components.PlanHistory` | Stateless component; renders `plan_history` as collapsible steps |
| `lib/lemon_sim_ui/live/components/run_log.ex` | `LemonSimUi.Live.Components.RunLog` | Stateless component; renders current status, recent events, and model-visible VendingBench tool/decision traces |
| `lib/lemon_sim_ui/live/components/memory_viewer.ex` | `LemonSimUi.Live.Components.MemoryViewer` | Reads scoped memory files from `LemonSim.Memory.Tools.memory_root/1` |
| `lib/lemon_sim_ui/live/components/skirmish_board.ex` | `LemonSimUi.Live.Components.SkirmishBoard` | Most complex board; full grid rendering + interactive move/attack controls |
| `lib/lemon_sim_ui/live/components/vending_bench_board.ex` | `LemonSimUi.Live.Components.VendingBenchBoard` | Retro vending-machine broadcast view with generated product sprites, Arena standings, supplier, refund, fault, trade, and scorecard display |
| `lib/lemon_sim_ui/live/components/tcg_shop_board.ex` | `LemonSimUi.Live.Components.TcgShopBoard` | TCG Shop dashboard for sealed lines, sealed openings, loose-pack inventory/sales, special-order deposits/fulfillment, supplier credit, damaged-delivery claims, supplier standing, financing, register cash/card tenders, bank deposits, drawer reconciliation, local returns, store credit, consignment payables, memberships, preorders, promotions, organized-play capacity/prize support, inventory aging, singles, market pulse, online marketplace channels, tax ledger, gross margin, fixed overhead, operating profit, refunds, channel costs, payroll, scheduled staffing, loss prevention, local competition, shrinkage, customers, and scorecard metrics |

## Common Modification Patterns

### Adding a New Simulation Domain

1. Implement the domain in `lemon_sim` (state, modules, updater, projector, action space, runner opts).
2. Add a `build_initial_state/3` clause in `SimManager` for the new domain atom.
3. Add `generate_id/1` clause in `SimManager`.
4. Add domain detection in `SimHelpers.infer_domain_type/1` (key a unique world map field).
5. Add `sim_summary` world summary clause in `SimHelpers`.
6. Add `domain_label/1` and `domain_badge_color/1` clauses in `SimHelpers`.
7. Create a board component in `lib/lemon_sim_ui/live/components/<domain>_board.ex`.
8. Alias the board component and add a `<% :domain -> %>` clause in the `render/1` case in `SimDashboardLive`.
9. Add the domain to the form `options` list in `SimDashboardLive.render/1`.
10. Add `min_players/1`, `max_players/1`, `default_player_count/1`, and `player_count_label/1` clauses if the domain uses player counts.

### Adding Interactive Human Play to a Domain

1. Detect whose turn it is in `SimManager.human_turn?/2` (pattern on a world key unique to the domain).
2. Add phx-event handlers in `SimDashboardLive` (e.g., `handle_event("human_action", ...)`) that call `SimManager.submit_human_move/2` with a `LemonSim.Kernel.Event`.
3. Render interactive controls in the board component, gated on the `interactive` attribute (set by the LiveView when `human_player != nil && sim_id in running`).

### Updating an Existing Board Component

Board components are pure stateless `Phoenix.Component` functions. They receive `:world` (the `LemonSim.Kernel.State.world` map) and optionally `:interactive`. They do not hold any state — all data is derived from `world` in the function body before the `~H"""` template.

When adding display fields, read them with `LemonCore.MapHelpers.get_key/2` (or the local `get_val/3` helper already defined in most board components) to tolerate both atom and string keys in the world map.
VendingBench board data may come from JSON checkpoint artifacts, so do not use `String.to_atom/1` for slot, product, supplier, or agent ids while rendering.

### Changing Runner Behavior (step interval, retry count)

`SimManager` contains the runner loop in `do_ai_loop/7`. Constants to adjust:

- `@max_step_retries` — number of retries on step error before giving up
- `Process.sleep(500)` between successful steps
- `Process.sleep(2000 * (retries + 1))` backoff on failure
- The human move timeout is `300_000` ms (5 minutes) in `do_interactive_loop/7`

### Adding Per-Seat Model Assignment to a Domain

Domains that support per-seat models use `build_multi_model_opts/5` in `SimManager`. To add this to a new domain:

1. Accept `player_count` and `model_specs` in `build_initial_state/3`.
2. Call `build_multi_model_opts/5` with a `:default_opts_fn` pointing to the domain's `default_opts/1`.
3. Add model picker rows to the launch form in `SimDashboardLive.render/1` (already templated for the `~w(werewolf stock_market survivor space_station auction diplomacy)` guard — extend that list).

For Werewolf specifically, the internal actor IDs are villager names (`"Alice"`, `"Bram"`, etc.), not `player_n` seat IDs. Any per-player metadata such as `model_assignments` or `character_profiles` must be keyed by those canonical names.

### Adding a New Model to the Launch Form

Edit `provider_options/0`, `model_options_for_provider/1`, and the default provider/model constants in `SimDashboardLive`. The spec format is `"provider:model_id"` — parsed by `SimManager.parse_model_spec/1` against the registered `Ai.Models` provider list, so canonical names like `openai-codex` and supported aliases like `openai_codex` both resolve.

## Design Boundaries

- Do not add simulation logic here. Game rules, event shapes, and world state mutations belong in `lemon_sim`.
- Board components must remain stateless function components. Do not convert them to LiveComponents unless there is a strong rendering-isolation reason.
- `SimManager` owns model-simulation runner PIDs. Hosted AI work is owned by `HostedGame.RoomServer` under the dedicated bounded `HostedGame.AiTaskSupervisor`; do not use the shared task supervisor for provider fanout.
- The omniscient `WerewolfBoard` is only for model admin/broadcast surfaces. Never reuse it for hosted humans. Hosted player/public/host data must come from role-safe projections; hiding markup after sending raw state is not sufficient.
- A hosted host is role-blind. Secret-phase actor IDs, roles, actions, votes, meetings, pack chat, investigations, items, journals, and model thoughts must not enter host/public projections or telemetry. Private rooms remain private after stop/completion.
- Hosted credentials stay in signed cookies and LiveView `socket.private`, never assigns, lifecycle logs, crash formatting, storage, telemetry, or exported replays. Keep Phoenix parameter filtering and shared LiveView lifecycle logging disabled when adding routes.
- Hosted commands must carry match and state epochs, accept only server-built legal actions, persist before acknowledgement, and namespace client idempotency IDs away from system timeout/AI IDs.
- Persisted turn deadlines are authoritative: late human or AI decisions must enqueue the timeout path, never win a mailbox race. Provider/decider randomness must be reset before the authoritative updater so exported replay hashes depend only on the stored game RNG and canonical events.
- Lobby and pre-start cancellation projections expose a sealed waiting state with no phase, day, actor, or role. Runtime terminal failures use a safe reason distinct from host stop/cancel and completed player views reveal the final role roster.
- Hosted child specs pass only room IDs and reload the latest Store row. Never capture a room snapshot in a restart MFA.
- Hosted feature disablement is a runtime kill switch: disabled boot must not recover room timers/AI, and API/LiveView operations must fail closed.
- Local SQLite/Registry/PubSub make hosted rooms single-node. Do not advertise horizontal replicas without distributed ownership, shared storage, and distributed PubSub.
- Buffered Werewolf watch pacing belongs in `lemon_sim_ui`, not `lemon_sim`. Use exact broadcast snapshots plus UI-side dwell heuristics for readability, but keep simulation rules and state transitions in `lemon_sim`.
- Always-on Werewolf rotates configured model specs one seat per attempted game and starts with fixed roles by sorted seat. Failed attempts must remain visible as reliability data without contributing game outcomes to ratings. Preserve this full-cycle role balance when changing arena planning, resumption, or league pruning.
- Werewolf evidence rendering must show the engine-provided reliability and interpretation, not only the clue prose, so spectators can distinguish a noisy lead from proof.
- VendingBench live-log model traces are compact `plan_history` entries from `SimManager`. Keep them to visible tool calls/results and domain summaries; do not try to expose provider-hidden chain-of-thought.
- `SimHelpers.infer_domain_type/1` uses world map key heuristics. If two domains share the same distinguishing key, ensure the more specific one is listed first in the `cond`.
- Keep `/admin` and `/admin/sims/:sim_id` on `SimDashboardLive` behind `RequireAccessToken`. Dedicated production releases require at least a 32-byte access token. Browsers authenticate through the CSRF-protected `/admin/login` form and receive an expiring signed-session marker; query-string credentials must remain rejected. `/api/admin/*` accepts bearer credentials only. `/`, `/leaderboards`, `/watch/:sim_id`, `/healthz`, and `/readyz` are intentionally public. The optional public VendingBench launcher is controlled by `LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER` and should stay limited to validated configured presets unless the route is moved behind auth.
- Keep `LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS`, `LEMON_SIM_UI_MAX_STORED_SIMS`, and per-arena `MAX_GAME_RECORDS` wired through runtime config, readiness, deployment examples, and tests when lifecycle/storage behavior changes.
- Keep every `LEMON_WEREWOLF_HOSTED_*` knob, HTTPS requirement, room TTL/retention, AI limit/model, readiness, `.env.example`, and deployment manifest coherent. Production room creation also requires a 32-byte `LEMON_WEREWOLF_HOST_CREATE_TOKEN`.
- Configure public benchmark discovery with `config :lemon_sim_ui, :suite_roots, ["/tmp/vending-suite"]`. The default reader accepts either a suite directory containing `suite.json` or a parent directory with child suite directories, logs malformed JSON, and skips bad files.
- Treat auto-loop and deployment wiring as an ops slice. Runtime env flags such as `LEMON_SIM_AUTO_LOOP` and deployment manifests such as `fly.toml` should stay coherent with `SimManager` auto-loop behavior, but separate from the general public/admin UI route changes.
- `MemoryViewer` reads files synchronously at render time (no caching). Keep it bounded to small memory namespaces; it already limits to 20 files and 4096 bytes per file.

## Testing

```bash
mix test apps/lemon_sim_ui
```

Tests use `ConnCase` which starts the full endpoint. `LemonSim.Kernel.Store` is live (not mocked) — tests that create state must clean up with `Store.delete_state/1`.

Run hosted browser QA with `HOSTED_WEREWOLF_SMOKE_URL=http://127.0.0.1:4090 npm --prefix apps/lemon_sim_ui/assets run smoke:hosted-werewolf`. It uses five isolated sessions and covers secret non-leakage, timeout, pause/resume, reconnect, completion, replay, rematch, reduced motion, keyboard focus, and phone/tablet/desktop layouts.

When writing new board component tests, use `render_component/2` from `Phoenix.LiveViewTest` with a `%{world: ...}` assign. Pass a minimal world map that exercises the branch under test rather than a full sim state.

When writing new `SimDashboardLive` tests, use `render_patch/2` to navigate between routes without remounting.

When writing `SpectatorLive` tests, assert against `render(view)` after pubsub-driven updates so the test exercises the connected LiveView path rather than only the initial disconnected HTML.
