defmodule LemonSim.Deciders.ToolLoopDecider do
  @moduledoc false

  defdelegate decide(context, tools, opts \\ []), to: LemonSim.LLM.Deciders.ToolLoopDecider
end
