defmodule CodingAgent.Tools.SkillManage do
  @moduledoc """
  Wrapper for the LemonSkills `skill_manage` tool in the coding agent namespace.
  """

  @doc """
  Return the `skill_manage` tool scoped to the current working directory.
  """
  @spec tool(String.t(), keyword()) :: AgentCore.Types.AgentTool.t()
  def tool(cwd, opts \\ []) do
    opts
    |> Keyword.put(:cwd, cwd)
    |> LemonSkills.Tools.SkillManage.tool()
  end
end
