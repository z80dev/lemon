defmodule CodingAgent.Tools do
  @moduledoc """
  Tool registry and factory functions for coding agent tools.

  Provides pre-configured tool sets for different use cases:
  - `coding_tools/2` - Full access tools (read, write, edit, multiedit, patch, bash, grep, find, glob, ls, webfetch, websearch, todoread, todowrite, task)
  - `read_only_tools/2` - Exploration tools (read only)
  - `all_tools/2` - All available tools as a map
  """

  alias CodingAgent.Tools.{
    Read,
    Write,
    Edit,
    MultiEdit,
    Patch,
    Bash,
    Grep,
    Find,
    Glob,
    Ls,
    WebFetch,
    WebSearch,
    TodoRead,
    TodoWrite,
    Truncate,
    Task
  }

  @doc """
  Get the default coding tools (read, write, edit, multiedit, patch, bash, grep, find, glob, ls, webfetch, websearch, todoread, todowrite, task).

  ## Options
  - Any options are passed through to individual tools
  """
  @spec coding_tools(String.t(), keyword()) :: [AgentCore.Types.AgentTool.t()]
  def coding_tools(cwd, opts \\ []) do
    [
      Read.tool(cwd, opts),
      Write.tool(cwd, opts),
      Edit.tool(cwd, opts),
      MultiEdit.tool(cwd, opts),
      Patch.tool(cwd, opts),
      Bash.tool(cwd, opts),
      Grep.tool(cwd, opts),
      Find.tool(cwd, opts),
      Glob.tool(cwd, opts),
      Ls.tool(cwd, opts),
      WebFetch.tool(cwd, opts),
      WebSearch.tool(cwd, opts),
      TodoRead.tool(cwd, opts),
      TodoWrite.tool(cwd, opts),
      Task.tool(cwd, opts)
    ]
  end

  @doc """
  Get read-only tools for exploration (read, grep, find, ls).
  """
  @spec read_only_tools(String.t(), keyword()) :: [AgentCore.Types.AgentTool.t()]
  def read_only_tools(cwd, opts \\ []) do
    [
      Read.tool(cwd, opts),
      Grep.tool(cwd, opts),
      Find.tool(cwd, opts),
      Ls.tool(cwd, opts)
    ]
  end

  @doc """
  Get all available tools as a map keyed by name.
  """
  @spec all_tools(String.t(), keyword()) :: %{String.t() => AgentCore.Types.AgentTool.t()}
  def all_tools(cwd, opts \\ []) do
    %{
      "read" => Read.tool(cwd, opts),
      "write" => Write.tool(cwd, opts),
      "edit" => Edit.tool(cwd, opts),
      "multiedit" => MultiEdit.tool(cwd, opts),
      "patch" => Patch.tool(cwd, opts),
      "bash" => Bash.tool(cwd, opts),
      "grep" => Grep.tool(cwd, opts),
      "find" => Find.tool(cwd, opts),
      "glob" => Glob.tool(cwd, opts),
      "ls" => Ls.tool(cwd, opts),
      "webfetch" => WebFetch.tool(cwd, opts),
      "websearch" => WebSearch.tool(cwd, opts),
      "todoread" => TodoRead.tool(cwd, opts),
      "todowrite" => TodoWrite.tool(cwd, opts),
      "truncate" => Truncate.tool(opts),
      "task" => Task.tool(cwd, opts)
    }
  end

  @doc """
  Get a specific tool by name.
  """
  @spec get_tool(String.t(), String.t(), keyword()) :: AgentCore.Types.AgentTool.t() | nil
  def get_tool(name, cwd, opts \\ []) do
    Map.get(all_tools(cwd, opts), name)
  end

  @doc """
  Get tools by a list of names.
  """
  @spec get_tools([String.t()], String.t(), keyword()) :: [AgentCore.Types.AgentTool.t()]
  def get_tools(names, cwd, opts \\ []) do
    all = all_tools(cwd, opts)
    Enum.map(names, &Map.get(all, &1)) |> Enum.reject(&is_nil/1)
  end
end
