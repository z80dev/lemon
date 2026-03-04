# LemonSim Agent Guide

## Quick Orientation

LemonSim is a reusable simulation harness core for tool-first LLM agents. It is intentionally domain-agnostic: it does not implement game rules, turn ordering, chance engines, or scoring. Instead, it defines contracts for ingesting events, projecting state into model context, generating legal actions, and running one decision turn.

Use this app when you need a fresh-context-per-decision loop backed by structured world state and compact historical context.

## Key Files

| File | Module | Purpose |
|---|---|---|
| `lib/lemon_sim/state.ex` | `LemonSim.State` | Persistent world snapshot and rolling windows |
| `lib/lemon_sim/event.ex` | `LemonSim.Event` | Canonical event envelope |
| `lib/lemon_sim/plan_step.ex` | `LemonSim.PlanStep` | Compact plan-history entries |
| `lib/lemon_sim/decision_frame.ex` | `LemonSim.DecisionFrame` | Snapshot fed to projector |
| `lib/lemon_sim/event_coalescer.ex` | `LemonSim.EventCoalescer` | Coalescing/filtering behaviour |
| `lib/lemon_sim/updater.ex` | `LemonSim.Updater` | Event -> state updater behaviour |
| `lib/lemon_sim/action_space.ex` | `LemonSim.ActionSpace` | Dynamic legal tools behaviour |
| `lib/lemon_sim/projector.ex` | `LemonSim.Projector` | Frame -> AI context behaviour |
| `lib/lemon_sim/projectors/toolkit.ex` | `LemonSim.Projectors.Toolkit` | Stable prompt-shape helpers (sections + deterministic JSON) |
| `lib/lemon_sim/projectors/sectioned_projector.ex` | `LemonSim.Projectors.SectionedProjector` | Default sectioned projector with pluggable builders/overrides |
| `lib/lemon_sim/decider.ex` | `LemonSim.Decider` | One-turn decision behaviour |
| `lib/lemon_sim/deciders/tool_loop_decider.ex` | `LemonSim.Deciders.ToolLoopDecider` | Concrete LLM/tool loop decider |
| `lib/lemon_sim/runner.ex` | `LemonSim.Runner` | Ingest-until-decision and decide-once orchestration |
| `lib/lemon_sim/store.ex` | `LemonSim.Store` | `LemonCore.Store` persistence wrapper |
| `lib/lemon_sim/bus.ex` | `LemonSim.Bus` | `LemonCore.Bus` topic helpers |
| `lib/lemon_sim/memory/tools.ex` | `LemonSim.Memory.Tools` | Scoped memory file tools (`memory_*`) |

## Design Boundaries

- Keep this app generic. Do not embed chess/poker/pokemon/vending-specific rules here.
- Keep legal action gating in `ActionSpace` implementations, not in prompt text.
- Keep updater logic deterministic and side-effect free aside from explicit persistence calls.
- Keep memory policy out of the core harness; expose memory via tools in the decider layer (see `LemonSim.Memory.Tools`).

## Testing

```bash
mix test apps/lemon_sim
```

Current tests cover state normalization/windowing, runner orchestration, memory tool filesystem safety, and tool-loop decider behavior.
