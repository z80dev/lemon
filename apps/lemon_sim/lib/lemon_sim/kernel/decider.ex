defmodule LemonSim.Kernel.Decider do
  @moduledoc """
  Behaviour for executing one model decision against a tool-constrained context.
  """

  @callback decide(
              context :: LemonAi.Types.Context.t(),
              tools :: [LemonAgent.Types.AgentTool.t()],
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}
end
