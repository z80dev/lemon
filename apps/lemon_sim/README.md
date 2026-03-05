# LemonSim

Reusable simulation harness primitives for tool-first LLM agents.

## Scope (Phase 0)

Phase 0 establishes the small reusable core:

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

## Module Inventory

| Module | Purpose |
|---|---|
| `LemonSim.State` | Persistent world state + rolling event window + intent + plan history |
| `LemonSim.Event` | Canonical simulation event envelope |
| `LemonSim.PlanStep` | Compact plan-history record |
| `LemonSim.DecisionFrame` | Per-decision snapshot built from stored state |
| `LemonSim.DecisionSignal` | `:skip` / `:decide` decision gating signal |
| `LemonSim.EventCoalescer` | Behaviour for coalescing/filtering incoming events |
| `LemonSim.Updater` | Behaviour for applying events and returning decision signals |
| `LemonSim.ActionSpace` | Behaviour for deciding which tools are exposed on the current turn |
| `LemonSim.Projector` | Behaviour for state -> `Ai.Types.Context` projection |
| `LemonSim.Projectors.Toolkit` | Stable prompt-shape helpers (sections + deterministic JSON) |
| `LemonSim.Projectors.SectionedProjector` | Reusable scaffold projector with pluggable section builders |
| `LemonSim.Decider` | Behaviour for one constrained model decision |
| `LemonSim.Deciders.ToolLoopPolicy` | Behaviour for tool-batch validation and terminal decision selection |
| `LemonSim.Deciders.ToolPolicies.SingleTerminal` | Default policy: support-tool chaining + one terminal decision |
| `LemonSim.DecisionAdapter` | Behaviour for adapting decider output into simulation events |
| `LemonSim.DecisionAdapters.ToolResultEvents` | Default adapter for tool results containing `"event"` / `"events"` |
| `LemonSim.Store` | `LemonCore.Store` wrapper for state persistence |
| `LemonSim.Bus` | `LemonCore.Bus` wrapper for sim topics |
| `LemonSim.Runner` | Ingest-until-decision + decide-once + composed `step/3` + `run_until_terminal/3` |
| `LemonSim.Deciders.ToolLoopDecider` | Bounded LLM/tool loop decider driven by a pluggable tool policy |
| `LemonSim.Memory.Tools` | Optional scoped file-memory tool bundle for long-term notes |

## Dependency Rationale

| Dependency | Why it is used |
|---|---|
| `lemon_core` | Persistent store and pubsub/event transport |
| `agent_core` | Tool contract (`AgentTool`) for legal action generation |
| `ai` | Shared model context types (`Ai.Types.Context`) |

## Test

```bash
mix test apps/lemon_sim
```
