defmodule LemonSim do
  @moduledoc """
  Lemon-native simulation harness primitives for tool-first LLM agents.

  LemonSim stays close to Lemon internals while keeping clear internal
  boundaries:

  - `LemonSim.Kernel` owns durable simulation contracts and state flow
  - `LemonSim.LLM` owns model/tool-loop execution and provider integration
  - `LemonSim.Bench` owns artifact, scorecard, manifest, and replay checks
  - `LemonSim.Examples` owns domain simulations

  The kernel-facing surface provides contracts for:

  - storing normalized simulation state (`LemonSim.Kernel.State`)
  - ingesting events with decision gating (`LemonSim.Kernel.Updater`)
  - coalescing high-frequency event streams (`LemonSim.Kernel.EventCoalescer`)
  - projecting state into per-decision context (`LemonSim.Kernel.Projector`)
  - generating the tools exposed for the current decision turn
    (`LemonSim.Kernel.ActionSpace`)
  - adapting decisions into simulation events, with a default adapter for
    tool-result event payloads (`LemonSim.Kernel.DecisionAdapter`)
  - executing one decision turn, a composed step, or a full loop until terminal
    (`LemonSim.Kernel.Runner`)

  Game/simulation-specific engines (turn management, chance systems, scoring)
  remain in example domains unless they become reusable benchmark or LLM
  infrastructure.
  """
end
