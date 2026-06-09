defmodule LemonSim.ActionSpace do
  @moduledoc false

  @callback tools(state :: LemonSim.Kernel.State.t(), opts :: keyword()) ::
              {:ok, [AgentCore.Types.AgentTool.t()]} | {:error, term()}
end
