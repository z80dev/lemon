defmodule LemonSim.Decider do
  @moduledoc false

  @callback decide(
              context :: Ai.Types.Context.t(),
              tools :: [AgentCore.Types.AgentTool.t()],
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}
end
