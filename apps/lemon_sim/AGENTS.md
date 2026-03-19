# LemonSim Agent Guide

## Quick Orientation

LemonSim is a reusable simulation harness core for tool-first LLM agents. It is intentionally domain-agnostic: it does not implement game rules, turn ordering, chance engines, or scoring. Instead, it defines contracts for ingesting events, projecting state into model context, generating legal actions, and running one decision turn.

Use this app when you need a fresh-context-per-decision loop backed by structured world state and compact historical context.

## Current Dogfood Examples

- `LemonSim.Examples.TicTacToe` is the smallest end-to-end example.
- `LemonSim.Examples.Skirmish` is the preferred dogfood case for more complex sims. It adds deterministic combat resolution, derived events, AP-based turn continuation, and turn advancement without making the core harness domain-specific.

## Key Files

| File | Module | Purpose |
|---|---|---|
| `lib/lemon_sim/state.ex` | `LemonSim.State` | Persistent world snapshot and rolling windows |
| `lib/lemon_sim/event.ex` | `LemonSim.Event` | Canonical event envelope |
| `lib/lemon_sim/plan_step.ex` | `LemonSim.PlanStep` | Compact plan-history entries |
| `lib/lemon_sim/decision_frame.ex` | `LemonSim.DecisionFrame` | Snapshot fed to projector |
| `lib/lemon_sim/event_coalescer.ex` | `LemonSim.EventCoalescer` | Coalescing/filtering behaviour |
| `lib/lemon_sim/updater.ex` | `LemonSim.Updater` | Event -> state updater behaviour |
| `lib/lemon_sim/action_space.ex` | `LemonSim.ActionSpace` | Turn-scoped tool exposure behaviour |
| `lib/lemon_sim/projector.ex` | `LemonSim.Projector` | Frame -> AI context behaviour |
| `lib/lemon_sim/projectors/toolkit.ex` | `LemonSim.Projectors.Toolkit` | Stable prompt-shape helpers (sections + deterministic JSON) |
| `lib/lemon_sim/projectors/sectioned_projector.ex` | `LemonSim.Projectors.SectionedProjector` | Default sectioned projector with pluggable builders/overrides |
| `lib/lemon_sim/decider.ex` | `LemonSim.Decider` | One-turn decision behaviour |
| `lib/lemon_sim/deciders/tool_loop_policy.ex` | `LemonSim.Deciders.ToolLoopPolicy` | Tool-batch validation + terminal decision policy behaviour |
| `lib/lemon_sim/deciders/tool_policies/single_terminal.ex` | `LemonSim.Deciders.ToolPolicies.SingleTerminal` | Default support-tool + one-terminal-action policy |
| `lib/lemon_sim/decision_adapter.ex` | `LemonSim.DecisionAdapter` | Decision -> event adaptation behaviour for decisions without direct top-level events |
| `lib/lemon_sim/decision_adapters/tool_result_events.ex` | `LemonSim.DecisionAdapters.ToolResultEvents` | Default adapter for tool results that return event payloads in `result_details` |
| `lib/lemon_sim/deciders/tool_loop_decider.ex` | `LemonSim.Deciders.ToolLoopDecider` | Concrete LLM/tool loop decider |
| `lib/lemon_sim/runner.ex` | `LemonSim.Runner` | Ingest-until-decision, decide-once, composed `step/3`, and `run_until_terminal/3` orchestration |
| `lib/lemon_sim/store.ex` | `LemonSim.Store` | `LemonCore.Store` persistence wrapper |
| `lib/lemon_sim/bus.ex` | `LemonSim.Bus` | `LemonCore.Bus` topic helpers |
| `lib/lemon_sim/memory/tools.ex` | `LemonSim.Memory.Tools` | Scoped memory file tools (`memory_*`) |
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
- Keep memory policy out of the core harness; pass memory tools in explicitly as an optional bundle (see `LemonSim.Memory.Tools`).
- Prefer direct top-level `"event"` / `"events"` on decision maps when a decider can produce them; use `DecisionAdapter` for shape translation or legacy paths rather than as mandatory ceremony.
- `ToolLoopDecider` is tool-first: assistant replies without tool calls are treated as errors, not text decisions.
- Use `driver_max_turns` for outer sim loops and `decision_max_turns` for inner model/tool retries; `max_turns` remains a backward-compatible fallback.
- `Runner.ingest_events/4` should report invalid coalescers as `{:error, {:invalid_coalescer, module}}`, not raise.
- `State.version` tracks all state mutations, not just appended events.
- When sim code reads world maps that may have string or atom keys, prefer `LemonCore.MapHelpers.get_key/2`.
- Werewolf has two distinct information views by design: player/projector context hides live `cast_vote` events and private night actions, while replay/video rendering is audience-omniscient and may show all roles plus hidden night decisions.
- Werewolf player/projector context is name-first: assigned display names should be used in public discussion/history, while tool calls still use stable internal ids such as `player_4`.
- Werewolf run scripts should use the onboarded Gemini CLI provider (`:google_gemini_cli`, user-facing alias `gemini`) plus Codex (`:"openai-codex"`) and Kimi models. `:google` is the separate AI Studio provider and will not use `mix lemon.onboard gemini` credentials.
- LemonSim game credential helpers should resolve OAuth-backed `api_key_secret` values through `Ai.Auth.OAuthSecretResolver` before handing them to providers. This matters for Gemini CLI, Antigravity, Copilot, and other providers whose stored secret payload is not itself the final runtime token format.
- `LemonSim.GameHelpers.Runner` supports `provider_min_interval_ms` for per-provider request spacing without changing core `LemonSim.Runner`. Werewolf uses this to slow `:google_gemini_cli` seats to one request every 5 seconds by default.
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
