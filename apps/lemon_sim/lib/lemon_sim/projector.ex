defmodule LemonSim.Projector do
  @moduledoc """
  Behaviour for projecting a decision frame into model-ready context.
  """

  @callback project(
              frame :: LemonSim.DecisionFrame.t(),
              tools :: [AgentCore.Types.AgentTool.t()],
              opts :: keyword()
            ) ::
              {:ok, Ai.Types.Context.t()} | {:error, term()}
end
