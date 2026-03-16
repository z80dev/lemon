defmodule LemonSkills.PathBoundary do
  @moduledoc """
  Cross-platform path boundary check.

  Determines whether a path is `base` itself or a descendant of `base`.
  Handles both POSIX (`/`) and Windows (`\\`) path separators so that the
  same check works correctly regardless of the host platform.
  """

  @doc """
  Returns `true` when `path` is `base` itself or a descendant of `base`.

  ## Examples

      iex> LemonSkills.PathBoundary.within?("/a/b", "/a/b")
      true

      iex> LemonSkills.PathBoundary.within?("/a/b", "/a/b/c")
      true

      iex> LemonSkills.PathBoundary.within?("/a/b", "/a/b-other")
      false

      iex> LemonSkills.PathBoundary.within?("C:\\\\Skills\\\\skill", "C:\\\\Skills\\\\skill\\\\file.txt")
      true

      iex> LemonSkills.PathBoundary.within?("C:\\\\Skills\\\\skill", "C:\\\\Skills\\\\skill-evil\\\\x")
      false

  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(base, path) when is_binary(base) and is_binary(path) do
    path == base or
      String.starts_with?(path, base <> "/") or
      String.starts_with?(path, base <> "\\")
  end
end
