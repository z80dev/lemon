defmodule LemonSim.Memory.Tools do
  @moduledoc false

  defdelegate tool_names(), to: LemonSim.LLM.Memory.Tools
  defdelegate build(opts \\ []), to: LemonSim.LLM.Memory.Tools
  defdelegate setup!(opts \\ []), to: LemonSim.LLM.Memory.Tools
  defdelegate memory_root(opts \\ []), to: LemonSim.LLM.Memory.Tools
end
