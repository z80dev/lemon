defmodule CodingAgent.Tools.PostToX do
  @moduledoc """
  Wrapper for the LemonSkills `post_to_x` tool in the coding agent tool namespace.
  """

  alias AgentCore.Types.AgentTool
  alias LemonSkills.Tools.PostToX, as: LemonPostToX

  @doc """
  Return the `post_to_x` tool.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    LemonPostToX.tool(opts)
  end
end
