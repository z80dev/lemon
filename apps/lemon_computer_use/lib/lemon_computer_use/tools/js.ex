defmodule LemonComputerUse.Tools.Js do
  @moduledoc """
  The `cua_js` tool: run JavaScript against the original computer-use runtime
  (`cua.getState()`, `cua.getApp(...)`, snapshots and UI actions). See
  `LemonComputerUse.Tools.Common` for how it is built and what it returns.
  """

  alias LemonComputerUse.Tools.Common

  @spec tool(keyword()) :: LemonAgent.Types.AgentTool.t()
  def tool(opts \\ []), do: Common.tool("js", opts)

  @spec tool(String.t(), keyword()) :: LemonAgent.Types.AgentTool.t()
  def tool(_cwd, opts), do: tool(opts)
end
