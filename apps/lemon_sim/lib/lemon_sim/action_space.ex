defmodule LemonSim.ActionSpace do
  @moduledoc """
  Behaviour for generating dynamic legal tools from current state.
  """

  @callback tools(state :: LemonSim.State.t(), opts :: keyword()) ::
              {:ok, [AgentCore.Types.AgentTool.t()]} | {:error, term()}
end
