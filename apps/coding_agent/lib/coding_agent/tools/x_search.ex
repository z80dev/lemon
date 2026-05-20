defmodule CodingAgent.Tools.XSearch do
  @moduledoc """
  Wrapper for the LemonSkills `x_search` tool in the coding agent tool namespace.
  """

  alias AgentCore.Types.AgentTool
  alias LemonSkills.Tools.XSearch, as: LemonXSearch

  @doc """
  Return the `x_search` tool.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    LemonXSearch.tool(opts)
  end
end
