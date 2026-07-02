# LemonSim

Reusable simulation harness primitives for tool-first LLM agents.

## Mission

LemonSim should become a mature BEAM-native platform for running, watching,
replaying, and benchmarking agent simulations. The flagship product targets are
Werewolf as a watchable social-deduction game and Vending Bench as a nested
operator/physical-worker business simulation. See
`../../docs/plans/lemon-sim-platform-mission-2026-05-12.md` for the current
mission plan and acceptance criteria.

## Scope (Phase 0)

LemonSim is intentionally Lemon-native. It may depend on `lemon_core`,
`agent_core`, and `ai`, but new work should keep these
internal boundaries clear:

- `LemonSim.Kernel` owns state, events, runner flow, updater/action/projector
  behaviours, decision adaptation, persistence, and pubsub helpers.
- `LemonSim.LLM` owns tool-loop deciders, tool policies, model/provider setup,
  provider throttling, shared live-run helpers, and transcript capture.
- `LemonSim.Bench` owns artifact writing, run manifests, scorecards, replay
  verification, suite runners, and leaderboard export.
- `LemonSim.Examples.*` owns domain rules, worlds, commands, facts, projections,
  scorecards, and baselines for each simulation.

Phase 0 establishes the small core:

- normalized state structs (`State`, `Event`, `PlanStep`, `DecisionFrame`)
- pluggable behaviours for projector/updater/action space/decider/decision adapter
- event coalescer contract for high-frequency feeds
- minimal persistence and pubsub wrappers (`Store`, `Bus`)
- lightweight runner for ingest + one decision turn + composed step helper
  plus `run_until_terminal/3` (`Runner`)

No turn manager, chance engine, scoring, or game-specific logic is included.

Phase 1 adds:

- `ToolLoopDecider` for real model/tool-call decision execution with pluggable tool policies
- file-scoped memory tools (`index.md` + read/write/patch/list/delete) as an optional bundle

## Examples

- `LemonSim.Examples.TicTacToe` is the minimal self-play example.
- `LemonSim.Examples.Skirmish` is the main dogfood example for richer sims: it
  exercises phase advancement, derived updater events, deterministic RNG, and a
  larger tactical action space.
- `LemonSim.Examples.Poker` wraps a pure no-limit hold'em engine in the
  LemonSim harness: legal action tools, updater-driven hand progression,
  visibility-aware projections, private note journaling, per-street hand
  history, optional per-hand blind schedules for tournament-style runs, and
  multi-hand chip-stack victory with benchmark stats.
- `LemonSim.Examples.Werewolf` is the social-deduction showcase target for
  readable live watching, replay storyboards, hidden-information boundaries,
  and role-aware metrics.
- `LemonSim.Examples.VendingBench` is the nested-agent operations benchmark
  target for the original Vending-Bench: operator strategy, physical-worker
  execution, suppliers, inventory, demand, pricing, incidents, and objective
  net-worth scoring. Free-form supplier messages intentionally reject
  multi-product order emails so ambiguous model attempts become visible
  benchmark events instead of silently confirming only the first parsed item.
- `LemonSim.Examples.VendingBench.Arena` is the Vending-Bench 2 / Arena
  follow-on surface: several operators run independent vending businesses in
  the same location, shared item prices create demand pressure, agents can
  message, pay, trade, sell supplier leads, trigger price wars, and surface
  collusion signals. The leaderboard scores each agent by final money balance.
- `LemonSim.Examples.TcgShop` is a single-operator local game store benchmark
  with Pokemon, Yu-Gi-Oh!, One Piece, Dragon Ball Super, and accessory product
  lines. It models sealed allocation, collection buying, singles liquidity,
  grading submissions, sealed-product opening into singles inventory,
  loose-pack preparation from sealed boxes with counter/event pack sales,
  buylist store credit, preorder deposits and release-day
  fulfillment, customer special orders/holds with deposit liability and stock
  reservation, weekly events with inventory-backed prize support and store-credit
  prize fallback, consignment singles with consignor payables, paid league
  memberships with deferred service liability/revenue recognition,
  short-run promotion campaigns, supplier-account standing tied to invoice
  payment behavior, working-capital credit-line debt with interest, partial
  distributor fills, distributor credit terms, damaged-delivery supplier claims, and accounts payable,
  inventory-constrained online-order fulfillment, backorders, stockout/service
  trust damage, persistent customer personas with loyalty/satisfaction,
  operator staff-hour limits, scheduled part-time staffing coverage,
  regular payroll, overtime/backlog pressure,
  loss-prevention controls that reduce shrinkage risk,
  COGS, gross-margin, fixed-overhead, and operating-profit accounting,
  sanctioned organized-play capacity/no-show/turn-away economics,
  inventory aging and stale-stock markdowns,
  release demand spikes, fatigue-driven shrinkage, loss-prevention controls, merchant/payment fees,
  shipping labels, online marketplace/listing fees, cash/card tender splits, register deposits, drawer reconciliation over/short, local returns/store-credit refunds, refunds/chargebacks, sales-tax
  liability/remittance, deterministic market repricing, collection
  condition/authentication risk, grade-result variance, local market share,
  competitor reactions to stockouts and shelf pricing, query-sensitive market
  research notes, counterparty transcript artifacts, explicit failure-mode
  scorecard flags, reputation, and net-worth scoring.

Run them with:

```bash
mix lemon.sim.tic_tac_toe
mix lemon.sim.skirmish
mix lemon.sim.poker
```

Vending Bench also has deterministic, no-LLM modes for CI and mechanics smoke
tests. `baseline` runs a conservative operator with legal slot-size stocking,
normal suppliers, and command/fact artifact emission. `pressure` uses the same
harness but intentionally exercises market research, a structured supplier
quote, adversarial suppliers, a shutdown notice, premium pricing, customer
refunds, and scorecard failure modes:

```bash
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci_fixture
mix lemon.sim.vending_bench --preset ci --offline-strategy pressure --sim-id vb_pressure_fixture
```

For byte-reproducible offline artifact bundles, pass an explicit `--seed`,
`--sim-id`, `--artifact-dir`, and `--deterministic-artifacts`. This pins manifest
timestamps and uses artifact-root-relative path labels inside generated reports
and replay metadata.

TCG Shop also has deterministic no-LLM modes. `baseline` keeps a conservative
cash-balanced local game store stocked across Pokemon, Yu-Gi-Oh!, One Piece,
Dragon Ball Super, and accessories. `pressure` deliberately exercises market
research, One Piece/Pokemon allocation pressure, local collection buys, grading
submissions, weekly events, online-order packing/backorders, singles and graded
card sell-through, supplier fill-rate shortfalls, customer loyalty/satisfaction,
preorder reservations and release shortfalls, local competitor pressure, market-share drift,
marketing spend and promoted sales, sales-tax remittance, merchant/payment
  fees, shipping labels, supplier invoice payment, supplier account standing,
  effective supplier credit limits, working-capital debt/interest, register cash deposits/reconciliation, buylist store-credit
  liability/redemption, customer special-order deposits/fulfillment,
  consignment commission and payout liabilities,
  paid membership sales with deferred revenue recognition,
  organized-play prize fulfillment, event capacity/no-shows/turn-aways, sealed-product opening EV, loose-pack prep/sell-through, local return policy/writeoffs, scheduled part-time staffing, stale accessory markdowns, COGS/gross margin, fixed overhead, operating profit, refunds/chargebacks, regular payroll,
overtime pressure, inventory shrinkage, stale-stock markdown pressure, condition markdowns, authentication
failures, stockout signals, and scorecard evidence:

```bash
mix lemon.sim.tcg_shop --preset ci --offline-strategy baseline --sim-id tcg_ci_baseline
mix lemon.sim.tcg_shop --preset ci --offline-strategy pressure --sim-id tcg_ci_pressure
mix lemon.sim.tcg_shop --preset stress --offline-strategy overextended --sim-id tcg_stress_bad_operator
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/tcg_shop/tcg_ci_baseline
mix lemon.sim.score apps/lemon_sim/priv/game_logs/tcg_shop/tcg_ci_baseline
```

TCG Shop supports the same `--deterministic-artifacts` mode for repeatable
offline bundles when `--seed`, `--sim-id`, and `--artifact-dir` are fixed.

`overextended` is intentionally realistic but poor operating behavior: it
overcommits preorders and special orders, draws the credit line, overspends on
marketing/events/channel setup, runs high shelf markups, and exposes the
resulting failure modes in the scorecard and `counterparty_transcript.json`.

Vending-Bench 1.0 benchmark runs use `--preset paper`, which sets the horizon
to 365 simulated days, uses a 2,000-turn driver budget, preserves the original
net-worth score, and applies 10-day unpaid-fee bankruptcy.

```bash
mix lemon.sim.vending_bench --preset paper --sim-id vb_paper
```

Vending-Bench 2 runs use `--preset v2`, which keeps the 365-day horizon and
uses money balance as the primary score. The V2 tool surface includes
deterministic market research, structured supplier quote ledgers, persistent
reminders, and supplier replies that expose adversarial pricing, negotiation,
delays, shutdowns, substitutions, and refunds. Add `--arena` for the
multi-agent Arena variant. The deterministic baseline supports up to five named
operators without model credentials; Arena agents use distinct pricing postures
so shared-location demand pressure and checkpointed nonzero-spread price-war
signals are visible in the event log:

```bash
mix lemon.sim.vending_bench --preset v2 --arena --offline-strategy baseline --arena-agents 5 --sim-id vb_arena
```

The offline mode writes a stable run bundle: `manifest.json`, `config.json`,
`hashes.json`, `final_world.json`, `events.jsonl`, `commands.jsonl`,
`facts.jsonl`, `actions.jsonl`, `tool_calls.jsonl`, `supplier_messages.json`,
`worker_history.json`, `operator_transcript.json`, `reminders.json`,
`scorecard.json`, `replay.json`, `replay.html`, prompt snapshots under
`prompts/`, and `report.md` artifacts under
`apps/lemon_sim/priv/game_logs/vending_bench/<sim_id>` unless `--artifact-dir`
is provided. Live model runs also write the same artifact bundle when
`--artifact-dir` is supplied, and the bundle is checkpointed after each live
operator turn so long runs still leave inspectable partial `final_world`,
event, command, fact, action, scorecard, replay, and report files if
interrupted. Artifact writes use tmp-file, fsync, and rename; the VendingBench
checkpoint registry is updated through a serialized atomic writer. Live runs
also persist each checkpointed state when `persist?` is enabled, allowing the
public watch UI to follow long CLI runs by sim id. Existing artifact
directories can be verified, scored, or used to rebuild the replay browser with:

```bash
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/vending_bench/<sim_id>
mix lemon.sim.score apps/lemon_sim/priv/game_logs/vending_bench/<sim_id>
mix lemon.sim.vending_bench_replay apps/lemon_sim/priv/game_logs/vending_bench/<sim_id>
```

`verify` checks `manifest.json`, the `hashes.json` schema, required benchmark
files, manifest integrity hashes, and hashed file contents. `score` uses the
same verifier before printing `scorecard.json`, so tampered scorecards or
reports are rejected instead of displayed.

Arena artifact directories write `final_world.json`, `arena_world.json`,
`arena_events.jsonl`, `arena_actions.jsonl`, `arena_scorecard.json`,
standard `scorecard.json`/`manifest.json`/`hashes.json`, and
`arena_report.md`. The arena runner registers the artifact directory in the
same VendingBench checkpoint registry, so `/watch/<sim_id>` can render the
multi-agent standings from the saved `final_world.json`. Arena scorecards and
reports include message, payment, trade, supplier-lead, nonzero-spread
price-war, and collusion-signal counts.

Interrupted live runs can resume from the latest checkpointed artifact bundle:

```bash
mix lemon.sim.vending_bench --preset paper --resume-artifact-dir apps/lemon_sim/priv/game_logs/vending_bench/<sim_id>
```

For stalled provider experiments, `--live-step-timeout-ms` can shorten the
outer live operator timeout while preserving checkpointed missed-turn artifacts.

A small deterministic fixture is checked in at
`apps/lemon_sim/priv/fixtures/vending_bench/ci_replay/`. Regenerate it with:

```bash
mix lemon.sim.vending_bench --preset ci --max-days 3 --max-turns 10 --seed 1 --sim-id vb_ci_fixture --offline-strategy baseline --artifact-dir apps/lemon_sim/priv/fixtures/vending_bench/ci_replay
```

The live operator tool surface includes deterministic supplier and market
research plus email-style supplier messaging. `research_suppliers` searches the
offline supplier corpus, and `research_market` searches deterministic demand,
price, redundancy, perishability, and Arena competition notes.
`send_supplier_message` can request quotes, place parsed orders with known
suppliers, and receive bounces for unknown addresses. Quote replies are
persisted in `supplier_quote_history` and exported with supplier messages. The
older structured `send_supplier_email` order tool remains available for
compatibility with existing tests and scripted runs. Supplier email tools are
terminal business actions; support tools are read/research/reminder actions.
Live runs also tell the operator to stop after at most two support tool calls
before choosing a terminal action, and the VendingBench runner
paces ZAI and Gemini CLI provider calls by default to avoid rate-limit failures
during support-heavy turns. Supplier behavior now covers negotiated discounts,
adversarial markups, deterministic delivery delays, shutdown notices, and
bait-and-switch substitutions with delivery provenance in the final world
state and scorecard incidents. Overpriced sales can now trigger deterministic
customer complaints and same-day refunds that feed the scorecard. Storage has
explicit capacity, delivery overflow discarding, batch aging, and deterministic
spoilage loss. Demand varies by weather, season/month, day of week, price
elasticity, stockouts, and stocked product variety. Scorecards include revenue,
cost of goods sold, gross profit, sales mix, per-supplier order/incident
ledgers, and explicit failure-mode flags for repeated invalid actions, chronic
stockouts, supplier overtrust, unmanaged spoilage, customer trust damage, task
abandonment, and cash-flow risk.
Benchmark-native reminder tools let the operator create, list, and complete
time-sensitive follow-ups in world state alongside file-memory notes. The
physical worker can also remove expired storage inventory and report machine
faults through worker-only tools whose events are validated by the authoritative
updater.
When a world includes Arena metadata, the operator also receives competitor,
message, payment, and trade tools. Those tools record benchmark-native PvP
events and use updater-side accounting for money and inventory.

## Module Inventory

| Module | Purpose |
|---|---|
| `LemonSim.Kernel` | Boundary namespace for durable simulation contracts and deterministic state flow |
| `LemonSim.Kernel.State` | Persistent world state + rolling event window + intent + plan history |
| `LemonSim.Kernel.Event` | Canonical simulation event envelope |
| `LemonSim.Kernel.PlanStep` | Compact plan-history record |
| `LemonSim.Kernel.DecisionFrame` | Per-decision snapshot built from stored state |
| `LemonSim.Kernel.DecisionSignal` | `:skip` / `:decide` decision gating signal |
| `LemonSim.Kernel.EventCoalescer` | Behaviour for coalescing/filtering incoming events |
| `LemonSim.Kernel.Updater` | Behaviour for applying events and returning decision signals |
| `LemonSim.Kernel.ActionSpace` | Behaviour for deciding which tools are exposed on the current turn |
| `LemonSim.Kernel.Projector` | Behaviour for state -> `Ai.Types.Context` projection |
| `LemonSim.Kernel.Decider` | Behaviour for one constrained decision |
| `LemonSim.Kernel.DecisionAdapter` | Behaviour for adapting decider output into simulation events |
| `LemonSim.Kernel.DecisionAdapters.ToolResultEvents` | Default adapter for tool results containing `"event"` / `"events"` in `result_details` |
| `LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents` | Adapter for preserving `"event"` / `"events"` payloads from every executed tool call |
| `LemonSim.Kernel.Store` | `LemonCore.Store` wrapper for state persistence |
| `LemonSim.Kernel.Bus` | `LemonCore.Bus` wrapper for sim topics |
| `LemonSim.Kernel.Runner` | Ingest-until-decision + decide-once + composed `step/3` + `run_until_terminal/3` |
| `LemonSim.LLM` | Boundary namespace for model/tool-loop execution and provider integration |
| `LemonSim.LLM.Projectors.Toolkit` | Stable prompt-shape helpers (sections + deterministic JSON) |
| `LemonSim.LLM.Projectors.SectionedProjector` | Reusable scaffold projector with pluggable section builders |
| `LemonSim.LLM.Deciders.ToolLoopPolicy` | Behaviour for tool-batch validation and terminal decision selection |
| `LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal` | Default policy: support-tool chaining + one terminal decision |
| `LemonSim.LLM.Deciders.ToolLoopDecider` | Bounded LLM/tool loop decider driven by a pluggable tool policy |
| `LemonSim.LLM.GameHelpers.Config` | Shared model/provider credential resolution |
| `LemonSim.LLM.GameHelpers.ProviderThrottle` | Provider request throttling with explicit process ownership |
| `LemonSim.LLM.GameHelpers.Runner` | Shared model-backed example runner |
| `LemonSim.LLM.Memory.Tools` | Optional scoped file-memory tool bundle for long-term notes |
| `LemonSim.Bench` | Boundary namespace for benchmark artifacts, scorecards, manifests, and replay checks |
| `LemonSim.Bench.Artifacts.AtomicFile` | Atomic artifact writes with tmp-file, sync, and rename |
| `LemonSim.Bench.Artifacts.Verifier` | Manifest and file-hash verifier for run artifact bundles |
| `LemonSim.Examples.Helpers` | Shared pure helpers for example implementations |

`LemonSim.LLM.Deciders.ToolLoopDecider` expects the model to terminate turns with a
tool call. If the assistant responds without any tool call, it returns
`{:error, {:tool_call_required, details}}` instead of producing a text-only
decision that `Runner.step/3` cannot ingest. VendingBench live runs convert
those blank or text-only turns into `action_rejected` events and continue. If
the provider keeps returning blank responses at the same state, the live runner
records a `wait_for_next_day` fallback so the operator misses the turn instead
of discarding the long benchmark checkpoint. Live operator steps also have an
outer timeout; a hung provider call is recorded with the same missed-turn
fallback path.

`Runner.run_until_terminal/3` and `ToolLoopDecider` use separate turn budgets:

- `driver_max_turns` limits outer simulation steps
- `decision_max_turns` limits inner LLM/tool loop retries

Both still fall back to `max_turns` for backward compatibility.

## Decision Event Flow

`Runner.step/3` prefers direct event-bearing decisions before consulting a
decision adapter:

- if a decider returns top-level `"event"` / `"events"`, the runner ingests
  them immediately
- otherwise, the configured `DecisionAdapter` is used
- exception: if a decision includes `"executed_calls"` and a non-default adapter
  is configured, the adapter runs first so support-tool events are not dropped

If an invalid coalescer is configured, `Runner.ingest_events/4` returns
`{:error, {:invalid_coalescer, module}}` instead of raising.

`ToolLoopDecider` rejects duplicate normalized tool names before model calls so
benchmark runs cannot silently replace one tool implementation with another.

`LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal` also copies any
`result_details.event(s)` from terminal tool calls onto the returned decision as
top-level `"events"` so the default tool-loop path can bypass extra adapter
plumbing while still preserving `result_details`.

VendingBench uses `SingleTerminal` plus
`LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents` so support-tool and
terminal-tool events are preserved through the same generic path. Its public
module is a facade; world setup, projection, artifact writing, offline strategy
execution, arena behavior, demand, suppliers, physical worker behavior,
performance, replay, and updater logic live in focused `vending_bench/*`
modules.
Supplier ordering uses command/fact separation: model-facing tools emit
`place_supplier_order`, and the updater validates quantity, supplier quote,
delivery metadata, and affordability before appending the authoritative
`supplier_order_placed` fact.

## Dependency Rationale

| Dependency | Why it is used |
|---|---|
| `lemon_core` | Persistent store and pubsub/event transport |
| `agent_core` | Tool contract (`AgentTool`) for legal action generation |
| `ai` | Shared model context types (`Ai.Types.Context`) |

## Notes

- `State.version` increments on all state mutations, not only event appends.
- Memory tools consistently bootstrap their scoped workspace (`index.md`) before
  file operations.
- Sim code should either keep a consistent world-map key convention or use
  `LemonCore.MapHelpers.get_key/2` when reading persisted state.

## Test

```bash
mix test apps/lemon_sim
```
