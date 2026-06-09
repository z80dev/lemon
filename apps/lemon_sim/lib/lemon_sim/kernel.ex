defmodule LemonSim.Kernel do
  @moduledoc """
  Internal namespace for LemonSim simulation contracts and deterministic state flow.

  Kernel modules own the durable simulation law: state envelopes, event ingestion,
  updater/action/projector behaviours, decision adaptation, replay-safe runner
  mechanics, persistence, and pubsub helpers. Kernel code may use Lemon primitives
  such as `LemonCore`, `Ai`, and `AgentCore`, but it should not own model-provider
  policy, benchmark scoring, artifact packaging, or example-specific rules.
  """
end
