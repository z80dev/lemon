defmodule CodingAgent.Tools.PathHelpers do
  @moduledoc """
  Shared path resolution helpers used across coding agent tools.

  Provides functions for expanding home directories, checking relative paths,
  determining workspace preference for memory-related paths, and full path
  resolution pipelines.
  """

  @doc """
  Expands a leading `~` in a path to the user's home directory.

  ## Examples

      iex> PathHelpers.expand_home("~/foo")
      "/Users/someone/foo"

      iex> PathHelpers.expand_home("/absolute/path")
      "/absolute/path"
  """
  @spec expand_home(String.t()) :: String.t()
  def expand_home("~" <> rest), do: Path.expand("~") <> rest
  def expand_home(path), do: path

  @doc """
  Returns true if the path starts with `./`, `../`, `.\\`, or `..\\`.

  These prefixes indicate the caller explicitly wants resolution relative to
  the current working directory, not the workspace directory.
  """
  @spec explicit_relative?(String.t()) :: boolean()
  def explicit_relative?(path) when is_binary(path) do
    String.starts_with?(path, "./") or String.starts_with?(path, "../") or
      String.starts_with?(path, ".\\") or String.starts_with?(path, "..\\")
  end

  @doc """
  Returns true if `path` should resolve against `workspace_dir` rather than
  the current working directory.

  This is the case for memory-related paths (`MEMORY.md`, `memory/`, and
  optionally the bare `memory` directory) when a non-empty workspace directory
  is provided and the path is not explicitly relative.

  ## Options

    * `:include_bare_memory` - when `true`, also matches the bare string
      `"memory"` (used by grep to search the memory directory). Defaults to `false`.
  """
  @spec prefer_workspace_for_path?(String.t(), String.t() | nil, keyword()) :: boolean()
  def prefer_workspace_for_path?(path, workspace_dir, opts \\ []) do
    include_bare = Keyword.get(opts, :include_bare_memory, false)

    is_binary(workspace_dir) and String.trim(workspace_dir) != "" and
      not explicit_relative?(path) and
      (path == "MEMORY.md" or String.starts_with?(path, "memory/") or
         String.starts_with?(path, "memory\\") or
         (include_bare and path == "memory"))
  end

  @doc """
  Full path resolution pipeline: expand home, then resolve to an absolute path.

  If the path is already absolute after home expansion, it is returned as-is.
  Otherwise it is joined with either `workspace_dir` (for memory paths) or
  `cwd`, and then expanded.

  ## Options

    * `:workspace_dir` - the workspace directory for memory-path resolution
    * `:include_bare_memory` - passed through to `prefer_workspace_for_path?/3`
    * `:expand` - when `true` (default), calls `Path.expand/1` on the joined result.
      Set to `false` to skip expansion (e.g. when the caller handles it separately).
  """
  @spec resolve_path(String.t(), String.t(), keyword()) :: String.t()
  def resolve_path(path, cwd, opts \\ []) do
    expanded = expand_home(path)
    workspace_dir = Keyword.get(opts, :workspace_dir)
    should_expand = Keyword.get(opts, :expand, true)

    if Path.type(expanded) == :absolute do
      expanded
    else
      base =
        if prefer_workspace_for_path?(expanded, workspace_dir, opts) do
          workspace_dir
        else
          cwd
        end

      joined = Path.join(base, expanded)

      if should_expand do
        Path.expand(joined)
      else
        joined
      end
    end
  end
end
