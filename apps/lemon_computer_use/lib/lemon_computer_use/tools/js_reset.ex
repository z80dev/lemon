defmodule LemonComputerUse.Tools.JsReset do
  @moduledoc """
  The `cua_js_reset` tool: reset the computer-use JavaScript session. Apps,
  windows and their state are left as they are.
  """

  alias LemonComputerUse.Tools.Common

  @spec tool(keyword()) :: LemonAgent.Types.AgentTool.t()
  def tool(opts \\ []), do: Common.tool("js_reset", opts)

  @spec tool(String.t(), keyword()) :: LemonAgent.Types.AgentTool.t()
  def tool(_cwd, opts), do: tool(opts)
end
