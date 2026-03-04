defmodule LemonSim.Decider do
  @moduledoc """
  Behaviour for executing one model decision against a tool-constrained context.
  """

  @callback decide(
              context :: Ai.Types.Context.t(),
              tools :: [AgentCore.Types.AgentTool.t()],
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}
end
