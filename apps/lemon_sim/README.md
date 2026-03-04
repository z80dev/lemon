# LemonSim

Reusable simulation harness primitives for tool-first LLM agents.

## Scope (Phase 0)

Phase 0 establishes the small reusable core:

- normalized state structs (`State`, `Event`, `PlanStep`, `DecisionFrame`)
- pluggable behaviours for projector/updater/action space/decider
- event coalescer contract for high-frequency feeds
- minimal persistence and pubsub wrappers (`Store`, `Bus`)
- lightweight runner for ingest + one decision turn (`Runner`)

No turn manager, chance engine, scoring, or game-specific logic is included.

Phase 1 adds:

- `ToolLoopDecider` for real model/tool-call decision execution
- file-scoped memory tools (`index.md` + read/write/patch/list/delete)

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
| `LemonSim.ActionSpace` | Behaviour for dynamic legal tool generation |
| `LemonSim.Projector` | Behaviour for state -> `Ai.Types.Context` projection |
| `LemonSim.Decider` | Behaviour for one constrained model decision |
| `LemonSim.Store` | `LemonCore.Store` wrapper for state persistence |
| `LemonSim.Bus` | `LemonCore.Bus` wrapper for sim topics |
| `LemonSim.Runner` | Ingest-until-decision + decide-once helpers |
| `LemonSim.Deciders.ToolLoopDecider` | Bounded LLM/tool loop decider with intermediate tool support |
| `LemonSim.Memory.Tools` | Scoped file-memory toolset for long-term notes |

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
