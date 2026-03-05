defmodule LemonSim do
  @moduledoc """
  Reusable simulation harness primitives for tool-first LLM agents.

  LemonSim is intentionally small and modular. It provides core contracts for:

  - storing normalized simulation state (`LemonSim.State`)
  - ingesting events with decision gating (`LemonSim.Updater`)
  - coalescing high-frequency event streams (`LemonSim.EventCoalescer`)
  - projecting state into per-decision context (`LemonSim.Projector`)
  - generating legal tool actions dynamically, including discrete legal-action
    maps compiled into tools (`LemonSim.ActionSpace`)
  - adapting decisions into simulation events, with a default adapter for
    tool-result event payloads (`LemonSim.DecisionAdapter`)
  - executing one decision turn, a composed step, or a full loop until terminal
    (`LemonSim.Runner`)

  Phase 0 includes contracts and lightweight helpers only. Game/simulation-specific
  engines (turn management, chance systems, scoring) remain outside this app.
  """
end
