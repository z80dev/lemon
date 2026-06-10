# LemonSim Agent Guide

## Quick Orientation

LemonSim is a Lemon-native simulation harness for tool-first LLM agents. It is intentionally close to Lemon internals, but it still keeps internal boundaries: kernel modules own simulation state flow, LLM modules own model/tool-loop execution, bench modules own artifact and scorecard mechanics, and examples own domain rules.

It is intentionally domain-agnostic at the kernel boundary: it does not implement game rules, turn ordering, chance engines, or scoring. Instead, it defines contracts for ingesting events, projecting state into model context, generating legal actions, and running one decision turn.

Use this app when you need a fresh-context-per-decision loop backed by structured world state and compact historical context.

The product mission is broader than test harnessing: LemonSim should become the
BEAM-native platform for simulations people can watch, replay, and benchmark.
Werewolf is the flagship watchable social-deduction game, and Vending Bench
is the flagship nested operator/physical-worker business simulation. Keep
`docs/plans/lemon-sim-platform-mission-2026-05-12.md` current when these
mission targets change.

## Current Dogfood Examples

- `LemonSim.Examples.TicTacToe` is the smallest end-to-end example.
- `LemonSim.Examples.Skirmish` is the preferred dogfood case for more complex sims. It adds deterministic combat resolution, derived events, AP-based turn continuation, and turn advancement without making the core harness domain-specific.
- `LemonSim.Examples.Poker` is a multi-hand no-limit hold'em example built around a pure table engine. It is the current reference for wrapping an existing deterministic game engine with LemonSim action-space/updater glue, private per-seat notes, visibility-aware projections, and benchmark-oriented performance summaries.
- `LemonSim.Examples.Poker` also supports optional per-hand blind schedules, so short tournament-style runs can raise pressure without changing the core harness.
- `LemonSim.Examples.Werewolf` is the showcase target for a proper watchable
  social-deduction game: readable phases, hidden-information discipline,
  replay/storyboard artifacts, and objective role/model metrics.
- `LemonSim.Examples.VendingBench` is the Vending-Bench 1.0 target: a full
  nested-agent business simulation with operator strategy, physical worker
  execution, suppliers, inventory, demand, incidents, UI, replay, and
  scorecard evidence. It supports deterministic offline baseline runs through
  `mix lemon.sim.vending_bench --preset ci --offline-strategy baseline`.
  Benchmark mode is `--preset paper` with a 365-day horizon, a 2,000-turn
  driver budget, 10-day unpaid-fee bankruptcy, and primary net-worth scoring.
  Offline runs write replay files plus supplier message, worker history,
  reminder, and operator transcript JSON artifacts; existing artifact
  directories can be rebuilt with `mix lemon.sim.vending_bench_replay DIR`.
  Live runs with `artifact_dir` checkpoint the artifact bundle after each
  operator turn so long runs leave partial worlds, events, scorecards,
  and replay browsers before terminal completion. Live checkpoints also persist
  state when `persist?` is enabled so `/watch/:sim_id` can follow CLI runs.
  Use `--resume-artifact-dir DIR` to continue a live run from the latest
  checkpoint after an interruption. VendingBench converts blank/text-only live
  model turns into benchmark-visible `action_rejected` events; repeated blank
  responses at the same state fall back to `wait_for_next_day`, recording that
  the operator missed the turn instead of losing the long run. Hung live model
  steps use the same missed-turn fallback after the outer step timeout, which
  the CLI can tune with `--live-step-timeout-ms` for stalled provider proof
  runs.
  A checked-in deterministic replay fixture lives under
  `priv/fixtures/vending_bench/ci_replay/`.
  Supplier discovery now includes deterministic `research_suppliers` support and
  terminal `send_supplier_message` / `send_supplier_email` actions with inbox/outbox
  persistence, known-supplier order confirmation, unknown-address bounces,
  negotiated discounts, deterministic delivery delays, shutdown notices, and
  bait-and-switch delivery provenance. Free-form supplier messages reject
  multi-product order emails so ambiguous model attempts become visible instead
  of silently confirming only the first parsed item. Live VendingBench runs pace ZAI and
  Gemini CLI provider calls by default and prompt the operator to end each turn
  after at most two support-tool calls. Customer complaints/refunds are modeled
  from overpriced sales and included in the scorecard. Storage capacity,
  delivery overflow, batch aging, spoilage loss, day-of-week/month effects, and
  product-variety demand effects are part of the benchmark state and scorecard.
  Scorecards also expose objective failure-mode flags for invalid actions,
  stockouts, supplier overtrust, spoilage, customer trust damage, task
  abandonment, and cash-flow risk. Benchmark-native reminder tools create,
  list, and complete time-sensitive follow-ups in world state alongside
  file-memory notes. Worker-only physical tools can remove expired storage
  inventory and report machine faults, with authoritative updater validation
  before world state changes.
- Vending-Bench 2 uses `mix lemon.sim.vending_bench --preset v2`; add
  `--arena --offline-strategy baseline --arena-agents N` for the multi-agent
  Arena surface. Arena runs keep individual machine/world state per operator,
  apply shared-location price pressure, record inter-agent messages/trades, and
  score the leaderboard by money balance.

## Key Files

Boundary namespaces:

| Namespace | Owns |
|---|---|
| `LemonSim.Kernel` | State, event envelopes, runner flow, updater/action/projector behaviours, decision adaptation, persistence, and pubsub helpers |
| `LemonSim.LLM` | Tool-loop deciders, tool policies, provider config/auth, provider throttling, shared live-run helpers, and transcripts |
| `LemonSim.Bench` | Atomic artifact writing, manifests, scorecards, replay verification, suite runners, and leaderboard exports |
| `LemonSim.Examples.*` | Domain worlds, commands, facts, projectors, action spaces, updaters, baselines, and domain scorecards |

| File | Module | Purpose |
|---|---|---|
| `lib/lemon_sim/kernel/state.ex` | `LemonSim.Kernel.State` | Persistent world snapshot and rolling windows |
| `lib/lemon_sim/kernel/event.ex` | `LemonSim.Kernel.Event` | Canonical event envelope |
| `lib/lemon_sim/kernel/plan_step.ex` | `LemonSim.Kernel.PlanStep` | Compact plan-history entries |
| `lib/lemon_sim/kernel/decision_frame.ex` | `LemonSim.Kernel.DecisionFrame` | Snapshot fed to projector |
| `lib/lemon_sim/kernel/event_coalescer.ex` | `LemonSim.Kernel.EventCoalescer` | Coalescing/filtering behaviour |
| `lib/lemon_sim/kernel/updater.ex` | `LemonSim.Kernel.Updater` | Event -> state updater behaviour |
| `lib/lemon_sim/kernel/action_space.ex` | `LemonSim.Kernel.ActionSpace` | Turn-scoped tool exposure behaviour |
| `lib/lemon_sim/kernel/projector.ex` | `LemonSim.Kernel.Projector` | Frame -> AI context behaviour |
| `lib/lemon_sim/kernel/decider.ex` | `LemonSim.Kernel.Decider` | One-turn decision behaviour |
| `lib/lemon_sim/kernel/decision_adapter.ex` | `LemonSim.Kernel.DecisionAdapter` | Decision -> event adaptation behaviour |
| `lib/lemon_sim/kernel/decision_adapters/tool_result_events.ex` | `LemonSim.Kernel.DecisionAdapters.ToolResultEvents` | Default adapter for tool results that return event payloads in `result_details` |
| `lib/lemon_sim/kernel/decision_adapters/executed_call_events.ex` | `LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents` | Adapter for preserving event payloads from every executed tool call |
| `lib/lemon_sim/llm/projectors/toolkit.ex` | `LemonSim.LLM.Projectors.Toolkit` | Stable prompt-shape helpers (sections + deterministic JSON) |
| `lib/lemon_sim/llm/projectors/sectioned_projector.ex` | `LemonSim.LLM.Projectors.SectionedProjector` | Default sectioned projector with pluggable builders/overrides |
| `lib/lemon_sim/llm/deciders/tool_loop_policy.ex` | `LemonSim.LLM.Deciders.ToolLoopPolicy` | Tool-batch validation + terminal decision policy behaviour |
| `lib/lemon_sim/llm/deciders/tool_policies/single_terminal.ex` | `LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal` | Default support-tool + one-terminal-action policy |
| `lib/lemon_sim/bench/artifacts/atomic_file.ex` | `LemonSim.Bench.Artifacts.AtomicFile` | Atomic artifact writes via tmp file, sync, and rename |
| `lib/lemon_sim/bench/artifacts/verifier.ex` | `LemonSim.Bench.Artifacts.Verifier` | Verifies run artifact manifests and file hashes |
| `lib/lemon_sim/llm/game_helpers/config.ex` | `LemonSim.LLM.GameHelpers.Config` | Shared model and provider credential resolution for sim runners |
| `lib/lemon_sim/llm/game_helpers/provider_throttle.ex` | `LemonSim.LLM.GameHelpers.ProviderThrottle` | Shared provider request throttling with explicit process stop |
| `lib/lemon_sim/llm/deciders/tool_loop_decider.ex` | `LemonSim.LLM.Deciders.ToolLoopDecider` | Concrete LLM/tool loop decider |
| `lib/lemon_sim/kernel/runner.ex` | `LemonSim.Kernel.Runner` | Ingest-until-decision, decide-once, composed `step/3`, and `run_until_terminal/3` orchestration |
| `lib/lemon_sim/kernel/store.ex` | `LemonSim.Kernel.Store` | `LemonCore.Store` persistence wrapper |
| `lib/lemon_sim/kernel/bus.ex` | `LemonSim.Kernel.Bus` | `LemonCore.Bus` topic helpers |
| `lib/lemon_sim/llm/memory/tools.ex` | `LemonSim.LLM.Memory.Tools` | Scoped memory file tools (`memory_*`) |
| `lib/lemon_sim/examples/skirmish.ex` | `LemonSim.Examples.Skirmish` | Tactical combat dogfood example for phased/derived-event sims |
| `lib/lemon_sim/examples/werewolf/replay_storyboard.ex` | `LemonSim.Examples.Werewolf.ReplayStoryboard` | Builds audience-omniscient Werewolf replay beats, including explicit night actions and vote swings |
| `lib/lemon_sim/examples/werewolf/transcript_logger.ex` | `LemonSim.Examples.Werewolf.TranscriptLogger` | Builds action-aware transcript entries so last-turn phase transitions do not hide statements, votes, or night actions |
| `lib/lemon_sim/examples/werewolf/performance.ex` | `LemonSim.Examples.Werewolf.Performance` | Produces role-aware benchmark metrics for hidden-information reasoning, vote quality, and night-action execution |
| `lib/lemon_sim/examples/survivor/performance.ex` | `LemonSim.Examples.Survivor.Performance` | Produces objective Survivor metrics for challenge conversion, whisper volume, vote quality, idol usage, and jury outcomes |
| `lib/lemon_sim/examples/diplomacy/performance.ex` | `LemonSim.Examples.Diplomacy.Performance` | Produces Diplomacy-lite metrics for negotiation volume, support usage, territory capture, and final board conversion |
| `lib/lemon_sim/examples/space_station/performance.ex` | `LemonSim.Examples.SpaceStation.Performance` | Produces Space Station Crisis metrics for crew utility, sabotage pressure, vote accuracy, and special-role usage |
| `lib/lemon_sim/examples/stock_market/performance.ex` | `LemonSim.Examples.StockMarket.Performance` | Produces Stock Market Arena metrics for call accuracy, whisper activity, trade execution, and portfolio returns |

## Design Boundaries

- Keep this app generic. Do not embed chess/poker/pokemon/vending-specific rules here.
- Keep `ActionSpace` focused on which tools are exposed this turn.
- Keep authoritative argument legality in updater logic, not prompt text or `ActionSpace`.
- Keep updater logic deterministic and side-effect free aside from explicit persistence calls.
- Keep memory policy out of the kernel harness; pass memory tools in explicitly as an optional bundle (see `LemonSim.LLM.Memory.Tools`).
- Put reusable benchmark artifact, manifest, scorecard, and replay-check mechanics under `LemonSim.Bench`.
- Put reusable model/provider/tool-loop mechanics under `LemonSim.LLM`.
- Prefer direct top-level `"event"` / `"events"` on decision maps when a decider can produce them; use `DecisionAdapter` for shape translation or legacy paths rather than as mandatory ceremony.
- If a decision includes `"executed_calls"` and a non-default adapter is configured, `Runner.step/3` adapts through that adapter before direct terminal events so support-tool events are preserved.
- VendingBench uses the generic `SingleTerminal` policy with `ExecutedCallEvents`; do not reintroduce benchmark-local copies of generic tool-loop policy or executed-call event extraction.
- Keep `LemonSim.Examples.VendingBench` as a facade. World bootstrap, projection, artifacts, offline baseline running, arena behavior, demand, suppliers, physical-worker behavior, performance, replay, and updater logic belong in focused `vending_bench/*` modules.
- `ToolLoopDecider` is tool-first: assistant replies without tool calls are treated as errors, not text decisions.
- `ToolLoopDecider` must reject duplicate normalized tool names; silent tool replacement invalidates benchmark traces.
- Use `driver_max_turns` for outer sim loops and `decision_max_turns` for inner model/tool retries; `max_turns` remains a backward-compatible fallback.
- `Runner.ingest_events/4` should report invalid coalescers as `{:error, {:invalid_coalescer, module}}`, not raise.
- VendingBench supplier orders are command/fact based: model-facing tools emit `place_supplier_order`, and the updater quotes suppliers and emits `supplier_order_placed`; do not trust model-origin payloads for cost, delivery day, substitutions, or affordability.
- VendingBench artifact files must be written atomically with `LemonSim.Bench.Artifacts.AtomicFile`. The artifact registry is mutable only through `VendingBench.ArtifactRegistry`, which serializes updates and writes atomically.
- `State.version` tracks all state mutations, not just appended events.
- When sim code reads world maps that may have string or atom keys, prefer `LemonCore.MapHelpers.get_key/2`.
- After event payloads are normalized into internal world state, prefer atom-keyed access in reducers and benchmark loops instead of repeated mixed-key fallback.
- Werewolf has two distinct information views by design: player/projector context hides live `cast_vote` events and private night actions, while replay/video rendering is audience-omniscient and may show all roles plus hidden night decisions.
- Werewolf player/projector context is name-first: assigned display names should be used in public discussion/history, while tool calls still use stable internal ids such as `player_4`.
- Werewolf run scripts should use the onboarded Gemini CLI provider (`:google_gemini_cli`, user-facing alias `gemini`) plus Codex (`:"openai-codex"`) and Kimi models. `:google` is the separate AI Studio provider and will not use `mix lemon.onboard gemini` credentials.
- LemonSim game credential helpers should resolve OAuth-backed `api_key_secret` values through `LemonAiRuntime.Auth.OAuthSecretResolver` before handing them to providers. This matters for Gemini CLI, Antigravity, Copilot, and other providers whose stored secret payload is not itself the final runtime token format.
- `LemonSim.LLM.GameHelpers.Runner` supports `provider_min_interval_ms` for per-provider request spacing without changing core `LemonSim.Kernel.Runner`. Werewolf uses this to slow `:google_gemini_cli` seats to one request every 5 seconds by default.
- Werewolf day play uses a hard cap on public discussion turns so accusations or back-and-forth cannot extend the phase indefinitely. Accusations may pull one future speaker forward for an immediate defense, but they must not rewind the floor to someone who already spoke or create 2-player bounce loops. Day 1 should still have enough room for real claim-and-response play when the board state sharpens quickly.
- Werewolf benchmark output should emphasize objective signals by role, such as correct wolf votes, wolf kill conversion, seer wolf checks, and doctor saves, rather than a single opaque score.
- The 5-player role table is intentionally `1 werewolf / 1 seer / 1 doctor / 2 villagers`; using 2 wolves at 5 seats creates trivial opening-night parity and is not a useful benchmark.
- Survivor challenge resolution should depend on strategy matchups, not per-seat randomness. If strategy choice does not matter, the sim stops measuring planning quality.
- Survivor benchmark output should include more than the winner. Favor signals such as challenge wins, whisper volume, correct elimination votes, idol usage, and jury vote conversion.
- Diplomacy benchmark output should include negotiation and execution signals such as messages sent, submitted/support orders, territories captured, and final territory count, not just the nominal winner.
- Space Station Crisis should remain a social-deduction benchmark, not a pure attrition sim. Keep public observables legible (room visits, round reports, revealed ejections), allow enough discussion for accusation updates, and end the game immediately when the crew ejects the saboteur.
- Stock Market Arena should make public talk mechanically relevant. Public calls should move sentiment, accurate calls should feed trader reputation, bearish views should be actionable via shorting/covering, private tips should stay asymmetric, and benchmark output should emphasize directional accuracy, profitable execution, and information-sharing choices rather than just final winner.

## Testing

```bash
mix test apps/lemon_sim
```

Current tests cover state normalization/windowing, runner orchestration, the default tool-result adapter, memory tool filesystem safety, tool-loop decider behavior, and the skirmish example's action space/updater/RNG path.

Poker coverage also exercises side pots, heads-up blind/button rules, multi-hand progression, rejection fallback auto-folding, and projection privacy boundaries.
