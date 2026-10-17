defmodule LemonOmp.Worktree do
  @moduledoc """
  Git worktrees created and owned by Lemon, never caller-supplied paths.

  Validation is read-only. Each invocation branches from the validated HEAD;
  cleanup is conservative, bounded to two seconds, and never uses force.
  """

  @command_timeout 5_000
  @cleanup_timeout 2_000

  def validate(_cwd, isolate) when isolate in [nil, false], do: {:ok, nil}

  def validate(cwd, true) do
    deadline = deadline(@command_timeout)

    with {:ok, "true"} <- git(cwd, ["rev-parse", "--is-inside-work-tree"], deadline),
         {:ok, common} <-
           git(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"], deadline),
         {:ok, listing} <- git(cwd, ["worktree", "list", "--porcelain", "-z"], deadline),
         {:ok, base} <- git(cwd, ["rev-parse", "HEAD"], deadline),
         ["worktree " <> repo | _] <- String.split(listing, <<0>>, trim: true) do
      {:ok, %{common: common, repo: repo, base: base}}
    else
      _ -> {:error, :not_a_git_repo}
    end
  end

  def validate(_cwd, _isolate), do: {:error, :invalid_params}

  @doc "Read-only inventory of existing, registered Lemon worktrees (at most 32)."
  def kept(cwd) do
    deadline = deadline(@command_timeout)

    with {:ok, repo} <- validate(cwd, true),
         {:ok, listing} <-
           git(cwd, ["worktree", "list", "--porcelain", "-z"], deadline) do
      listing
      |> String.split(<<0, 0>>, trim: true)
      |> Enum.take(256)
      |> Enum.flat_map(fn record ->
        fields = String.split(record, <<0>>, trim: true)

        path =
          Enum.find_value(
            fields,
            &(String.starts_with?(&1, "worktree ") && String.replace_prefix(&1, "worktree ", ""))
          )

        branch =
          Enum.find_value(
            fields,
            &(String.starts_with?(&1, "branch refs/heads/") &&
                String.replace_prefix(&1, "branch refs/heads/", ""))
          )

        root = Path.join(repo.common, "lemon-omp-worktrees")

        if is_binary(path) and is_binary(branch) and
             Path.dirname(path) == root and
             branch == "lemon-omp/" <> Path.basename(path) and
             File.dir?(path) and not match?({:ok, %{type: :symlink}}, File.lstat(path)) and
             not match?({:ok, %{type: :symlink}}, File.lstat(root)) do
          [Map.merge(repo, %{path: path, branch: branch})]
        else
          []
        end
      end)
      |> Enum.take(32)
      |> Enum.flat_map(fn worktree ->
        case git(
               cwd,
               ["reflog", "show", "--format=%H%x00%gs", "--max-count=1000", worktree.branch],
               deadline
             ) do
          {:ok, output} ->
            base =
              output
              |> String.split("\n", trim: true)
              |> Enum.find_value(fn entry ->
                case String.split(entry, <<0>>, parts: 2) do
                  [hash, "branch: Created from " <> _] -> hash
                  _ -> nil
                end
              end)

            [%{worktree | base: base}]

          _ ->
            [%{worktree | base: nil}]
        end
      end)
    else
      _ -> []
    end
  end

  def create(nil, _id), do: {:ok, nil}

  def create(repo, id) do
    path = Path.join([repo.common, "lemon-omp-worktrees", id])
    branch = "lemon-omp/" <> id
    worktree = Map.merge(repo, %{path: path, branch: branch})
    deadline = deadline(@command_timeout)

    # Separate branch creation establishes ownership before attempting checkout.
    case git(repo.repo, ["branch", "--", branch, repo.base], deadline) do
      {:ok, _} ->
        case git(
               repo.repo,
               ["-c", "core.hooksPath=/dev/null", "worktree", "add", path, branch],
               deadline
             ) do
          {:ok, _} ->
            {:ok, worktree}

          _ ->
            cleanup(worktree)
            {:error, :worktree_failed}
        end

      _ ->
        {:error, :worktree_failed}
    end
  end

  def wire(nil), do: nil

  def wire(worktree) do
    %{
      "path" => worktree.path,
      "branch" => worktree.branch,
      "base" => if(worktree.base, do: String.slice(worktree.base, 0, 12)),
      "repo" => worktree.repo
    }
  end

  def cleanup(nil), do: nil

  def cleanup(worktree) do
    deadline = deadline(@cleanup_timeout)
    dirty = dirty_count(worktree, deadline)
    commits = commit_count(worktree, deadline)

    removed =
      if dirty == 0 and commits == 0 do
        remove(worktree, deadline)
      else
        false
      end

    wire(worktree)
    |> Map.merge(%{"kept" => not removed, "dirty" => dirty, "commits" => commits})
  end

  defp dirty_count(worktree, deadline) do
    if File.dir?(worktree.path) do
      case git(
             worktree.path,
             ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
             deadline
           ) do
        {:ok, output} -> count_status(String.split(output, <<0>>, trim: true), 0)
        _ -> nil
      end
    else
      0
    end
  end

  # Renames/copies have a second NUL-delimited pathname, not another change.
  defp count_status([], count), do: count

  defp count_status([<<x, y, _::binary>>, _from | rest], count)
       when x in [?R, ?C] or y in [?R, ?C], do: count_status(rest, count + 1)

  defp count_status([_ | rest], count), do: count_status(rest, count + 1)

  defp commit_count(%{base: nil}, _deadline), do: nil

  defp commit_count(worktree, deadline) do
    case git(
           worktree.repo,
           ["rev-list", "--count", worktree.base <> ".." <> worktree.branch, "--"],
           deadline
         ) do
      {:ok, count} ->
        case Integer.parse(count) do
          {count, ""} -> count
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp remove(worktree, deadline) do
    removed =
      if File.exists?(worktree.path),
        do: match?({:ok, _}, git(worktree.repo, ["worktree", "remove", worktree.path], deadline)),
        else: true

    # Compare-and-delete protects a branch changed after the cleanliness check.
    removed and
      match?(
        {:ok, _},
        git(
          worktree.repo,
          ["update-ref", "-d", "refs/heads/" <> worktree.branch, worktree.base],
          deadline
        )
      )
  end

  defp git(cwd, args, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)
    env = for {key, _} <- System.get_env(), String.starts_with?(key, "LEMON_"), do: {key, nil}

    task =
      Task.async(fn ->
        try do
          LemonCore.NativeProcess.cmd("git", ["-C", cwd | args],
            stderr_to_stdout: true,
            env: [{"GIT_TERMINAL_PROMPT", "0"} | env]
          )
        rescue
          _ -> {"", 1}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, String.trim_trailing(output, "\n")}
      _ -> {:error, :git_failed}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
