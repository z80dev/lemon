defmodule LemonSim.ActionSpace do
  @moduledoc """
  Behaviour for generating the tools exposed for the current decision turn.

  `ActionSpace` decides which tools are available right now. It does not need to
  encode full argument legality. In complex sims, tool execution can simply
  package arguments into event payloads and leave authoritative validation to the
  updater.
  """

  @callback tools(state :: LemonSim.State.t(), opts :: keyword()) ::
              {:ok, [AgentCore.Types.AgentTool.t()]} | {:error, term()}
end
