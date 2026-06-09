defmodule LemonSim.Projector do
  @moduledoc false

  @callback project(
              frame :: LemonSim.Kernel.DecisionFrame.t(),
              tools :: [AgentCore.Types.AgentTool.t()],
              opts :: keyword()
            ) ::
              {:ok, Ai.Types.Context.t()} | {:error, term()}
end
