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

## Testing

```bash
mix test apps/lemon_sim
```

Current tests cover state normalization/windowing, runner orchestration, the default tool-result adapter, memory tool filesystem safety, tool-loop decider behavior, and the skirmish example's action space/updater/RNG path.
