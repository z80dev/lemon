defmodule LemonOmp.Worktree do
  @moduledoc """
  Git worktrees created and owned by Lemon, never caller-supplied paths.

  Validation is read-only. Each invocation branches from the validated HEAD;
  cleanup is conservative, bounded to two seconds, and never uses force.

  Every read (validation, the session-discovery inventory and its reflog
  lookups, and cleanup's dirty and commit counts) runs through
  `LemonCore.SafeGit`, so a repository's configuration (signature display and
  `gpg.program`, fsmonitor, filter drivers, includes) cannot make listing or
  cleaning up omp sessions run a program. Only the explicit isolation writes
  (`branch`, `worktree add/remove`, `update-ref`) use the repository as is.
  """

  alias LemonCore.SafeGit

  @command_timeout 5_000
  @cleanup_timeout 2_000

  def validate(_cwd, isolate) when isolate in [nil, false], do: {:ok, nil}

  def validate(cwd, true) do
    deadline = deadline(@command_timeout)

    with {:ok, safe} <- SafeGit.repository(cwd),
         {:ok, real} <- LemonCore.TrustedRoot.realpath(cwd),
         false <- metadata?(real, safe),
         {:ok, repo} <- main_worktree(safe),
         {:ok, base} <- read(safe, ["rev-parse", "--verify", "HEAD"], deadline) do
      {:ok, %{common: safe.common_dir, repo: repo, base: base}}
    else
      _ -> {:error, :not_a_git_repo}
    end
  end

  def validate(_cwd, _isolate), do: {:error, :invalid_params}

  # `cwd` inside Git metadata rather than in a work tree (Lemon's own worktrees
  # live under the common directory, so the root decides).
  defp metadata?(cwd, %{root: root, git_dir: git_dir, common_dir: common}) do
    in_metadata? = fn path ->
      LemonCore.TrustedRoot.inside?(path, git_dir) or LemonCore.TrustedRoot.inside?(path, common)
    end

    in_metadata?.(cwd) and not in_metadata?.(root)
  end

  # The main worktree: the validated root when `cwd` is in it, else the
  # directory holding the common `.git` directory.
  defp main_worktree(%{git_dir: same, common_dir: same, root: root}), do: {:ok, root}

  defp main_worktree(%{common_dir: common}) do
    if Path.basename(common) == ".git", do: {:ok, Path.dirname(common)}, else: :error
  end

  @doc "Read-only inventory of existing, registered Lemon worktrees (at most 32)."
  def kept(cwd) do
    deadline = deadline(@command_timeout)

    with {:ok, repo} <- validate(cwd, true),
         {:ok, safe} <- SafeGit.repository(cwd),
         {:ok, listing} <- read(safe, ["worktree", "list", "--porcelain", "-z"], deadline) do
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
        case read(
               safe,
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
    with true <- File.dir?(worktree.path),
         {:ok, safe} <- SafeGit.repository(worktree.path) do
      case read(safe, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], deadline,
             cd: worktree.path
           ) do
        {:ok, output} -> count_status(String.split(output, <<0>>, trim: true), 0)
        _ -> nil
      end
    else
      false -> 0
      _ -> nil
    end
  end

  # Renames/copies have a second NUL-delimited pathname, not another change.
  defp count_status([], count), do: count

  defp count_status([<<x, y, _::binary>>, _from | rest], count)
       when x in [?R, ?C] or y in [?R, ?C], do: count_status(rest, count + 1)

  defp count_status([_ | rest], count), do: count_status(rest, count + 1)

  defp commit_count(%{base: nil}, _deadline), do: nil

  defp commit_count(worktree, deadline) do
    with {:ok, safe} <- SafeGit.repository(worktree.repo),
         {:ok, count} <-
           read(
             safe,
             ["rev-list", "--count", worktree.base <> ".." <> worktree.branch, "--"],
             deadline
           ),
         {count, ""} <- Integer.parse(count) do
      count
    else
      _ -> nil
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

  # Reads through SafeGit, bounded by the caller's deadline.
  defp read(safe, args, deadline, opts \\ []) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 1)

    case SafeGit.run(safe, args, [timeout_ms: timeout, max_bytes: 4_000_000] ++ opts) do
      {:ok, output, 0} -> {:ok, String.trim_trailing(output, "\n")}
      _ -> {:error, :git_failed}
    end
  end

  # Isolation writes: the operator-trusted executable, never one from PATH.
  defp git(cwd, args, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)
    env = for {key, _} <- System.get_env(), String.starts_with?(key, "LEMON_"), do: {key, nil}

    task =
      Task.async(fn ->
        try do
          with {:ok, git} <- SafeGit.executable() do
            LemonCore.NativeProcess.cmd(git, ["-C", cwd | args],
              stderr_to_stdout: true,
              env: [{"GIT_TERMINAL_PROMPT", "0"} | env]
            )
          else
            _ -> {"", 1}
          end
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
