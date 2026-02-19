defmodule CodingAgent.Tools.GetXMentions do
  @moduledoc """
  Wrapper for the LemonSkills `get_x_mentions` tool in the coding agent tool namespace.
  """

  alias AgentCore.Types.AgentTool
  alias LemonSkills.Tools.GetXMentions, as: LemonGetXMentions

  @doc """
  Return the `get_x_mentions` tool.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    LemonGetXMentions.tool(opts)
  end
end
