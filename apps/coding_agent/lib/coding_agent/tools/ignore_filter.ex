defmodule CodingAgent.Tools.IgnoreFilter do
  @moduledoc """
  `.gitignore`/`.ignore` filtering for the Elixir fallbacks of `find` and
  `grep`, matching what `fd`/`rg` skip by default.

  Filtering uses `git check-ignore` when the search directory is inside a git
  work tree. Outside a work tree, without git, or when the search is rooted in
  an ignored directory, paths are returned unfiltered (like fd/rg).
  """

  # `git check-ignore` prints the ignored subset of its arguments (exit 0),
  # nothing (exit 1), or fails outside a work tree (exit 128).
  @check_ignore_chunk 200

  @doc "Drops the paths git would ignore, relative to the `search_dir` work tree."
  @spec reject_ignored([String.t()], String.t()) :: [String.t()]
  def reject_ignored([], _search_dir), do: []

  def reject_ignored(paths, search_dir) do
    case git_ignored(paths, search_dir) do
      {:ok, ignored} -> Enum.reject(paths, &MapSet.member?(ignored, &1))
      :unavailable -> paths
    end
  end

  defp git_ignored(paths, search_dir) do
    with git when is_binary(git) <- System.find_executable("git"),
         {:ok, root_ignored} <- check_ignore(git, search_dir, [search_dir]),
         true <- MapSet.size(root_ignored) == 0 do
      paths
      |> Enum.chunk_every(@check_ignore_chunk)
      |> Enum.reduce_while({:ok, MapSet.new()}, fn chunk, {:ok, acc} ->
        case check_ignore(git, search_dir, chunk) do
          {:ok, ignored} -> {:cont, {:ok, MapSet.union(acc, ignored)}}
          :unavailable -> {:halt, :unavailable}
        end
      end)
    else
      _ -> :unavailable
    end
  end

  defp check_ignore(git, search_dir, paths) do
    args = ["-C", search_dir, "check-ignore", "--" | paths]

    case System.cmd(git, args, stderr_to_stdout: false) do
      {output, status} when status in [0, 1] ->
        {:ok, output |> String.split("\n", trim: true) |> MapSet.new()}

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  end
end
