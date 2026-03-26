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

Run them with:

```bash
mix lemon.sim.tic_tac_toe
mix lemon.sim.skirmish
mix lemon.sim.poker
```

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
| `LemonSim.DecisionAdapter` | Behaviour for adapting decider output into simulation events when a decision does not already carry direct events |
| `LemonSim.DecisionAdapters.ToolResultEvents` | Default adapter for tool results containing `"event"` / `"events"` in `result_details` |
| `LemonSim.Store` | `LemonCore.Store` wrapper for state persistence |
| `LemonSim.Bus` | `LemonCore.Bus` wrapper for sim topics |
| `LemonSim.Runner` | Ingest-until-decision + decide-once + composed `step/3` + `run_until_terminal/3` |
| `LemonSim.Deciders.ToolLoopDecider` | Bounded LLM/tool loop decider driven by a pluggable tool policy |
| `LemonSim.Memory.Tools` | Optional scoped file-memory tool bundle for long-term notes |

`LemonSim.Deciders.ToolLoopDecider` expects the model to terminate turns with a
tool call. If the assistant responds without any tool call, it returns
`{:error, {:tool_call_required, details}}` instead of producing a text-only
decision that `Runner.step/3` cannot ingest.

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

If an invalid coalescer is configured, `Runner.ingest_events/4` returns
`{:error, {:invalid_coalescer, module}}` instead of raising.

`LemonSim.Deciders.ToolPolicies.SingleTerminal` also copies any
`result_details.event(s)` from terminal tool calls onto the returned decision as
top-level `"events"` so the default tool-loop path can bypass extra adapter
plumbing while still preserving `result_details`.

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
