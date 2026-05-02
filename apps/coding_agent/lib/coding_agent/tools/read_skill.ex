defmodule CodingAgent.Tools.ReadSkill do
  @moduledoc """
  Wrapper for the LemonSkills `read_skill` tool in the coding agent tool namespace.

  Lemon system prompts instruct agents to call `read_skill` after selecting a
  relevant skill from the prompt's `<available_skills>` section. Keeping this
  wrapper in `coding_agent` lets the standard tool factories and dynamic tool
  registry expose that LemonSkills tool with the same `tool(cwd, opts)` shape as
  the rest of the coding tools.
  """

  @doc """
  Return the `read_skill` tool scoped to the current working directory.
  """
  @spec tool(String.t(), keyword()) :: AgentCore.Types.AgentTool.t()
  def tool(cwd, opts \\ []) do
    opts
    |> Keyword.put(:cwd, cwd)
    |> LemonSkills.Tools.ReadSkill.tool()
  end
end
