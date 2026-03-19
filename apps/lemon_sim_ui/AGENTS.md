# LemonSimUi Agent Guide

## Quick Orientation

`lemon_sim_ui` is a Phoenix LiveView dashboard for the `lemon_sim` simulation harness. It does not contain any simulation logic — all game rules, runners, and domain examples live in `lemon_sim`. This app is responsible for:

- launching simulations via `SimManager`
- driving the runner loop (calling `LemonSim.Runner.step/3` in a supervised task)
- rendering live state in the browser via `SimDashboardLive` and the public read-only `SpectatorLive` werewolf watcher
- exposing a token-protected admin API for remote sim start/stop
- accepting human-player moves for interactive domains

The primary entry points for changes are `SimManager`, `SimDashboardLive`, `SpectatorLive`, and the board component for the relevant domain.

## File Structure

```
lib/
  lemon_sim_ui.ex                          Web context macros (router/live_view/html helpers)
  lemon_sim_ui/
    application.ex                         OTP application: supervisor tree
    endpoint.ex                            Bandit HTTP endpoint + LiveView socket
    router.ex                              Private admin routes, public `/watch/:sim_id`, and `/api/admin/*`
    sim_manager.ex                         GenServer: owns all running sim tasks
    sim_helpers.ex                         Pure helpers: domain inference, labels, colors
    werewolf_playback.ex                   Buffered live-playback helper for readable Werewolf spectator pacing
    telemetry.ex                           Phoenix telemetry setup
    gettext.ex                             Gettext backend
    components/
      core_components.ex                   Shared form/button/flash components
      layouts.ex                           App/root layout modules
      layouts/app.html.heex
      layouts/root.html.heex
    controllers/
      admin_sim_controller.ex              Token-protected JSON API for start/stop
      error_html.ex                        404/500 HTML error views
      error_json.ex                        JSON error views
      health_controller.ex                 Public `/healthz` endpoint
    live/
      sim_dashboard_live.ex                Main LiveView (lobby + detail)
      spectator_live.ex                    Public read-only werewolf spectator view
    plugs/
      require_access_token.ex              Optional bearer/query/session token gate
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
test/
  lemon_sim_ui/
    live/
      sim_dashboard_live_test.exs
      components/board_components_test.exs
  support/
    conn_case.ex
  test_helper.exs
```

## Key Modules

| File | Module | Purpose |
|---|---|---|
| `lib/lemon_sim_ui/sim_manager.ex` | `LemonSimUi.SimManager` | Central GenServer; `start_sim/2`, `stop_sim/1`, `list_running/0`, `submit_human_move/2` |
| `lib/lemon_sim_ui/live/sim_dashboard_live.ex` | `LemonSimUi.SimDashboardLive` | Dashboard LiveView for `/` and `/sims/:sim_id`; handles sim launch and admin/detail flows |
| `lib/lemon_sim_ui/live/spectator_live.ex` | `LemonSimUi.SpectatorLive` | Public shareable werewolf watcher for `/watch/:sim_id`; subscribes to sim + lobby updates |
| `lib/lemon_sim_ui/werewolf_playback.ex` | `LemonSimUi.WerewolfPlayback` | Buffers exact Werewolf state snapshots and enforces minimum dwell times so live dialogue/night beats stay readable |
| `lib/lemon_sim_ui/controllers/admin_sim_controller.ex` | `LemonSimUi.AdminSimController` | Protected JSON API for remote sim start/stop |
| `lib/lemon_sim_ui/controllers/health_controller.ex` | `LemonSimUi.HealthController` | Public load-balancer/smoke-test health check |
| `lib/lemon_sim_ui/plugs/require_access_token.ex` | `LemonSimUi.Plugs.RequireAccessToken` | Optional access-token gate for dashboard + admin API |
| `lib/lemon_sim_ui/sim_helpers.ex` | `LemonSimUi.SimHelpers` | `infer_domain_type/1`, `sim_summary/1`, `domain_label/1`, `domain_badge_color/1` |
| `lib/lemon_sim_ui/live/components/event_log.ex` | `LemonSimUi.Live.Components.EventLog` | Stateless component; renders `recent_events` with color-coded event kinds |
| `lib/lemon_sim_ui/live/components/plan_history.ex` | `LemonSimUi.Live.Components.PlanHistory` | Stateless component; renders `plan_history` as collapsible steps |
| `lib/lemon_sim_ui/live/components/memory_viewer.ex` | `LemonSimUi.Live.Components.MemoryViewer` | Reads scoped memory files from `LemonSim.Memory.Tools.memory_root/1` |
| `lib/lemon_sim_ui/live/components/skirmish_board.ex` | `LemonSimUi.Live.Components.SkirmishBoard` | Most complex board; full grid rendering + interactive move/attack controls |

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

1. Detect whose turn it is in `SimManager.is_human_turn?/2` (pattern on a world key unique to the domain).
2. Add phx-event handlers in `SimDashboardLive` (e.g., `handle_event("human_action", ...)`) that call `SimManager.submit_human_move/2` with a `LemonSim.Event`.
3. Render interactive controls in the board component, gated on the `interactive` attribute (set by the LiveView when `human_player != nil && sim_id in running`).

### Updating an Existing Board Component

Board components are pure stateless `Phoenix.Component` functions. They receive `:world` (the `LemonSim.State.world` map) and optionally `:interactive`. They do not hold any state — all data is derived from `world` in the function body before the `~H"""` template.

When adding display fields, read them with `LemonCore.MapHelpers.get_key/2` (or the local `get_val/3` helper already defined in most board components) to tolerate both atom and string keys in the world map.

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

Edit `available_model_options/0` and `@default_models` in `SimDashboardLive`. The spec format is `"provider:model_id"` — parsed by `SimManager.parse_model_spec/1` against the registered `Ai.Models` provider list, so canonical names like `openai-codex` and supported aliases like `openai_codex` both resolve.

## Design Boundaries

- Do not add simulation logic here. Game rules, event shapes, and world state mutations belong in `lemon_sim`.
- Board components must remain stateless function components. Do not convert them to LiveComponents unless there is a strong rendering-isolation reason.
- `SimManager` is the single owner of all runner task PIDs. Do not start runner tasks outside of it.
- Werewolf board context is not viewer-gated anymore. The dashboard and the public watcher should show the same non-admin story panels, including wolf chat history, private meetings, journals, and character bios.
- Buffered Werewolf watch pacing belongs in `lemon_sim_ui`, not `lemon_sim`. Use exact broadcast snapshots plus UI-side dwell heuristics for readability, but keep simulation rules and state transitions in `lemon_sim`.
- `SimHelpers.infer_domain_type/1` uses world map key heuristics. If two domains share the same distinguishing key, ensure the more specific one is listed first in the `cond`.
- Keep `/` and `/sims/:sim_id` on `SimDashboardLive` behind `RequireAccessToken` when a token is configured. `/watch/:sim_id` and `/healthz` are intentionally public.
- `MemoryViewer` reads files synchronously at render time (no caching). Keep it bounded to small memory namespaces; it already limits to 20 files and 4096 bytes per file.

## Testing

```bash
mix test apps/lemon_sim_ui
```

Tests use `ConnCase` which starts the full endpoint. `LemonSim.Store` is live (not mocked) — tests that create state must clean up with `Store.delete_state/1`.

When writing new board component tests, use `render_component/2` from `Phoenix.LiveViewTest` with a `%{world: ...}` assign. Pass a minimal world map that exercises the branch under test rather than a full sim state.

When writing new `SimDashboardLive` tests, use `render_patch/2` to navigate between routes without remounting.

When writing `SpectatorLive` tests, assert against `render(view)` after pubsub-driven updates so the test exercises the connected LiveView path rather than only the initial disconnected HTML.
