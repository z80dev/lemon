defmodule CodingAgent.Tools.Task.Worktree do
  @moduledoc """
  Prepares an isolated Git worktree for a native child task and, depending on
  the merge mode, merges the child's changes back after it succeeds.

  The caller supplies a generated task ID containing only ASCII letters, digits,
  underscores and hyphens, beginning with a letter or digit (at most 128 bytes).
  Worktrees live in the repository's common Git directory under
  `lemon-task-worktrees/<task_id>` on branch `lemon/task-<task_id>`.

  Merge modes:

    * `"none"` - the worktree starts at HEAD with tracked files only and is
      retained with its branch for review or cherry-picking. Uncommitted files,
      local configuration and credentials are not copied.
    * `"patch"` - the parent checkout's work in progress (tracked changes plus
      untracked, non-ignored files) is replayed into the worktree and committed
      as a baseline. On success, the child's changes relative to that baseline
      are applied to the parent checkout with `git apply`; a patch that does not
      apply cleanly leaves the parent untouched and keeps the worktree, branch
      and patch file.
    * `"branch"` - the worktree starts at HEAD. On success, the child's changes
      are committed on the task branch, the worktree is removed and the branch
      is kept for review. The branch is never merged into the user's branch.

  Existing paths and branches are never reused or removed.
  """

  alias LemonAgent.AbortSignal

  @type mode :: String.t()
  @type prepared :: %{
          required(:cwd) => String.t(),
          required(:worktree_path) => String.t(),
          required(:branch) => String.t(),
          optional(:base_commit) => String.t(),
          optional(:baseline_commit) => String.t(),
          optional(:merge) => map()
        }

  @modes ["none", "patch", "branch"]
  @max_untracked_bytes 64 * 1024 * 1024
  @max_listed_files 50
  @max_path_bytes 200
  @identity [
    "-c",
    "user.name=Lemon",
    "-c",
    "user.email=lemon@localhost",
    "-c",
    "commit.gpgsign=false"
  ]
  @diff_flags [
    "--binary",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-relative",
    "--ignore-submodules=all",
    "--src-prefix=a/",
    "--dst-prefix=b/"
  ]

  @doc "Supported merge modes."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @spec prepare(String.t(), String.t(), mode()) :: {:ok, prepared()} | {:error, String.t()}
  def prepare(cwd, task_id, mode \\ "none")

  def prepare(cwd, task_id, mode)
      when is_binary(cwd) and is_binary(task_id) and mode in @modes do
    with :ok <- validate_id(task_id),
         {:ok, git} <- git_executable(),
         {:ok, root} <- repository_root(git, cwd),
         {:ok, prefix} <- run_git(git, cwd, ["rev-parse", "--show-prefix"]),
         {:ok, common} <-
           run_git(git, root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         parent = Path.join(common, "lemon-task-worktrees"),
         :ok <- prepare_parent(parent),
         {:ok, prepared} <- create(git, root, prefix, parent, task_id) do
      setup_merge(git, root, parent, task_id, prepared, mode)
    end
  end

  def prepare(cwd, task_id, mode) when is_binary(cwd) and is_binary(task_id),
    do: {:error, "Unknown worktree merge mode #{inspect(mode)}"}

  def prepare(_, _, _), do: {:error, "Worktree cwd and task ID must be strings"}

  @doc """
  Merges a successful child's worktree changes according to the prepared merge
  mode. `source_cwd` is the parent task's cwd; its repository root receives
  patch-mode changes. The optional captured abort signal is rechecked before
  mutation and after acquiring the patch merge lock. Finalization refuses a
  replaced checkout or changed child branch. Returns a public merge summary map.
  """
  @spec finalize(prepared(), String.t(), String.t(), String.t() | nil, term()) :: map()
  def finalize(prepared, source_cwd, task_id, description, signal \\ nil)

  def finalize(%{merge: %{mode: "patch"}} = prepared, source_cwd, task_id, _description, signal) do
    with :ok <- check_abort(signal),
         {:ok, git} <- git_executable(),
         {:ok, root} <- repository_root(git, source_cwd),
         :ok <- validate_child_checkout(git, prepared),
         {:ok, files} <- stage_changes(git, prepared, prepared.baseline_commit) do
      finalize_patch(git, root, prepared, task_id, files, signal)
    else
      {:error, reason} -> merge_error("patch", prepared, reason)
    end
  end

  def finalize(%{merge: %{mode: "branch"}} = prepared, source_cwd, task_id, description, signal) do
    with :ok <- check_abort(signal),
         {:ok, git} <- git_executable(),
         {:ok, root} <- repository_root(git, source_cwd),
         :ok <- validate_child_checkout(git, prepared),
         {:ok, files} <- stage_changes(git, prepared, "HEAD"),
         :ok <- check_abort(signal),
         {:ok, _} <- commit_staged(git, prepared, files, task_id, description),
         {:ok, count} <-
           run_git(git, prepared.worktree_path, [
             "rev-list",
             "--count",
             prepared.base_commit <> "..HEAD"
           ]) do
      finalize_branch(git, root, prepared, count)
    else
      {:error, reason} -> merge_error("branch", prepared, reason)
    end
  end

  def finalize(%{merge: %{mode: mode}}, _source_cwd, _task_id, _description, _signal),
    do: %{mode: mode, status: "retained"}

  def finalize(_prepared, _source_cwd, _task_id, _description, _signal),
    do: %{mode: "none", status: "retained"}

  defp check_abort(signal) do
    if AbortSignal.aborted?(signal), do: {:error, "Task aborted"}, else: :ok
  end

  # Never stage a replaced checkout or delete detached/switched-branch commits.
  defp validate_child_checkout(git, prepared) do
    with {:ok, root} <- repository_root(git, prepared.worktree_path),
         true <- root == prepared.worktree_path,
         {:ok, branch} <- run_git(git, root, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         true <- branch == prepared.branch do
      :ok
    else
      _ -> {:error, "Task worktree is no longer on its original checkout and branch"}
    end
  end

  @doc "One short visible line describing a merge summary, or nil."
  @spec summary(map()) :: String.t() | nil
  def summary(%{status: "applied", mode: mode} = merge),
    do:
      "Merged task changes into the parent checkout (#{mode}, #{plural(merge.files_total, "file")})."

  def summary(%{status: "no_changes"}),
    do: "No task changes to merge; removed the task worktree."

  def summary(%{status: "conflict"} = merge),
    do:
      "Task changes did not apply cleanly to the parent checkout, so nothing was applied. " <>
        "Patch kept at #{merge.patch_path}; worktree kept at #{merge.worktree_path}."

  def summary(%{status: "committed"} = merge),
    do:
      "Committed task changes on branch #{merge.branch} (#{String.slice(merge.head, 0, 12)}); " <>
        "review and merge it manually."

  def summary(%{status: "error"} = merge),
    do: "Could not merge task changes (#{merge.reason}); worktree kept at #{merge.worktree_path}."

  def summary(_merge), do: nil

  defp validate_id(task_id) do
    if byte_size(task_id) in 1..128 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, task_id) do
      :ok
    else
      {:error,
       "Invalid worktree task ID: use 1-128 letters, digits, underscores or hyphens, starting with a letter or digit"}
    end
  end

  defp git_executable do
    case System.find_executable("git") do
      nil -> {:error, "Git executable is required to prepare a task worktree"}
      git -> {:ok, git}
    end
  end

  defp repository_root(git, cwd) do
    case run_git(git, cwd, ["rev-parse", "--show-toplevel"]) do
      {:ok, root} -> {:ok, root}
      {:error, _} -> {:error, "Cannot prepare task worktree: cwd is not a Git working tree"}
    end
  end

  defp prepare_parent(parent) do
    case File.mkdir(parent) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(parent) do
          {:ok, %{type: :directory}} -> :ok
          _ -> {:error, "Task worktree parent is not a directory"}
        end

      {:error, _} ->
        {:error, "Cannot create task worktree parent directory"}
    end
  end

  defp create(git, root, prefix, parent, task_id) do
    path = Path.join(parent, task_id)
    branch = "lemon/task-#{task_id}"

    # Reserve the path atomically before creating a branch. In particular, an
    # existing empty directory or dangling symlink must not become ours to clean.
    case File.mkdir(path) do
      :ok ->
        case run_git(git, root, ["branch", branch, "HEAD"]) do
          {:ok, _} ->
            checkout(git, root, prefix, path, branch)

          {:error, reason} ->
            File.rmdir(path)
            {:error, reason}
        end

      {:error, :eexist} ->
        {:error, "Task worktree path already exists"}

      {:error, _} ->
        {:error, "Cannot reserve task worktree path"}
    end
  end

  defp checkout(git, root, prefix, path, branch) do
    case run_git(git, root, ["worktree", "add", "--", path, branch]) do
      {:ok, _} ->
        child_cwd = Path.expand(prefix, path)

        if File.dir?(child_cwd) do
          {:ok, %{cwd: child_cwd, worktree_path: path, branch: branch}}
        else
          cleanup(git, root, path, branch, "Task cwd does not exist in the committed Git tree")
        end

      {:error, reason} ->
        cleanup(git, root, path, branch, reason)
    end
  end

  defp setup_merge(_git, _root, _parent, _task_id, prepared, "none"), do: {:ok, prepared}

  defp setup_merge(git, root, parent, task_id, prepared, mode) do
    %{worktree_path: path, branch: branch} = prepared

    result =
      with {:ok, base} <- run_git(git, path, ["rev-parse", "HEAD"]),
           {:ok, extra} <- replay_wip(git, root, parent, task_id, path, mode) do
        {:ok,
         prepared
         |> Map.put(:base_commit, base)
         |> Map.merge(extra)
         |> Map.put(:merge, %{mode: mode, status: "pending"})}
      end

    case result do
      {:ok, prepared} -> {:ok, prepared}
      {:error, reason} -> cleanup(git, root, path, branch, reason)
    end
  end

  defp replay_wip(_git, _root, _parent, _task_id, _path, "branch"), do: {:ok, %{}}

  defp replay_wip(git, root, parent, task_id, path, "patch") do
    with :ok <- replay_tracked(git, root, Path.join(parent, task_id <> ".wip.patch"), path),
         :ok <- replay_untracked(git, root, path),
         {:ok, _} <- run_git(git, path, ["add", "-A"]),
         {:ok, _} <-
           run_git(
             git,
             path,
             [
               "commit",
               "--no-verify",
               "--allow-empty",
               "-q",
               "-m",
               "lemon: task #{task_id} baseline"
             ],
             @identity
           ),
         {:ok, baseline} <- run_git(git, path, ["rev-parse", "HEAD"]) do
      {:ok, %{baseline_commit: baseline}}
    end
  end

  defp replay_tracked(git, root, patch, path) do
    with :ok <- reserve_file(patch) do
      try do
        with {:ok, _} <-
               run_git(git, root, ["diff"] ++ @diff_flags ++ ["--output=" <> patch, "HEAD"]) do
          apply_if_nonempty(git, path, patch)
        end
      after
        File.rm(patch)
      end
    end
  end

  defp apply_if_nonempty(git, path, patch) do
    case File.stat(patch) do
      {:ok, %{size: 0}} ->
        :ok

      {:ok, _} ->
        case run_git(git, path, ["apply", "--binary", "--whitespace=nowarn", "--", patch]) do
          {:ok, _} ->
            :ok

          {:error, _} ->
            {:error, "Could not replay the parent checkout's changes into the task worktree"}
        end

      {:error, _} ->
        {:error, "Could not read the parent checkout's changes"}
    end
  end

  defp replay_untracked(git, root, path) do
    with {:ok, output} <-
           run_git(git, root, ["ls-files", "--others", "--exclude-standard", "-z", "--full-name"]) do
      entries =
        output
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&safe_relative?/1)
        |> Enum.map(&{&1, File.lstat(Path.join(root, &1))})

      total =
        for {_rel, {:ok, %{type: :regular, size: size}}} <- entries, reduce: 0 do
          acc -> acc + size
        end

      if total > @max_untracked_bytes do
        {:error,
         "Untracked files in the parent checkout exceed #{div(@max_untracked_bytes, 1024 * 1024)} MiB; " <>
           "commit, ignore or remove them, or use merge=branch"}
      else
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case copy_untracked(root, path, entry) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end
    end
  end

  defp copy_untracked(root, path, {rel, {:ok, %{type: :regular, mode: mode}}}) do
    source = Path.join(root, rel)
    dest = Path.join(path, rel)

    with true <- safe_destination?(path, rel),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- clear_destination(dest),
         :ok <- File.cp(source, dest),
         :ok <- File.chmod(dest, Bitwise.band(mode, 0o777)) do
      :ok
    else
      false -> :ok
      _ -> {:error, "Could not copy an untracked parent file into the task worktree"}
    end
  end

  defp copy_untracked(root, path, {rel, {:ok, %{type: :symlink}}}) do
    source = Path.join(root, rel)
    dest = Path.join(path, rel)

    with {:ok, target} <- File.read_link(source),
         :relative <- Path.type(target),
         true <- inside?(Path.expand(target, Path.dirname(source)), root),
         true <- safe_destination?(path, rel),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- clear_destination(dest),
         :ok <- File.ln_s(target, dest) do
      :ok
    else
      {:error, _} -> {:error, "Could not copy an untracked parent symlink into the task worktree"}
      # Absolute or escaping symlinks are skipped so the child stays isolated.
      _ -> :ok
    end
  end

  defp copy_untracked(_root, _path, _entry), do: :ok

  defp safe_relative?(rel) do
    Path.type(rel) == :relative and not String.ends_with?(rel, "/") and
      Enum.all?(Path.split(rel), &(&1 not in [".", "..", ".git"]))
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Never write through a symlinked directory inside the worktree.
  defp safe_destination?(path, rel) do
    rel
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.reduce_while({true, path}, fn part, {true, dir} ->
      next = Path.join(dir, part)

      case File.lstat(next) do
        {:ok, %{type: :directory}} -> {:cont, {true, next}}
        {:error, :enoent} -> {:halt, {true, next}}
        _ -> {:halt, {false, next}}
      end
    end)
    |> elem(0)
  end

  defp clear_destination(dest) do
    case File.lstat(dest) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :directory}} -> {:error, :eisdir}
      {:ok, _} -> File.rm(dest)
      error -> error
    end
  end

  defp stage_changes(git, prepared, against) do
    path = prepared.worktree_path

    with {:ok, _} <- run_git(git, path, ["add", "-A"]),
         {:ok, output} <-
           run_git(git, path, [
             "diff",
             "--cached",
             "--name-only",
             "-z",
             "--no-relative",
             "--ignore-submodules=all",
             against
           ]) do
      {:ok, String.split(output, <<0>>, trim: true)}
    end
  end

  defp finalize_patch(git, root, prepared, _task_id, [], signal) do
    case check_abort(signal) do
      :ok -> no_changes(git, root, prepared, "patch")
      {:error, reason} -> merge_error("patch", prepared, reason)
    end
  end

  defp finalize_patch(git, root, prepared, task_id, files, signal) do
    patch = Path.join(Path.dirname(prepared.worktree_path), task_id <> ".patch")

    with :ok <- reserve_file(patch),
         :ok <- write_patch(git, prepared, patch) do
      outcome =
        serialized(root, fn ->
          with :ok <- check_abort(signal), do: apply_patch(git, root, patch, signal)
        end)

      case outcome do
        :ok ->
          File.rm(patch)

          %{
            mode: "patch",
            status: "applied",
            files: bounded_files(files),
            files_total: length(files)
          }
          |> with_cleanup(remove_resources(git, root, prepared, true))

        {:conflict, conflicting} ->
          %{
            mode: "patch",
            status: "conflict",
            reason: "Patch does not apply cleanly to the parent checkout",
            patch_path: patch,
            worktree_path: prepared.worktree_path,
            branch: prepared.branch,
            files: bounded_files(files),
            files_total: length(files),
            conflicting_files: conflicting
          }

        {:error, reason} ->
          "patch" |> merge_error(prepared, reason) |> Map.put(:patch_path, patch)
      end
    else
      {:error, reason} -> merge_error("patch", prepared, reason)
    end
  end

  defp write_patch(git, prepared, patch) do
    args = ["diff", "--cached"] ++ @diff_flags ++ ["--output=" <> patch, prepared.baseline_commit]

    case run_git(git, prepared.worktree_path, args) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        File.rm(patch)
        {:error, reason}
    end
  end

  defp apply_patch(git, root, patch, signal) do
    apply = ["apply", "--binary", "--whitespace=nowarn"]

    case git_cmd(git, root, apply ++ ["--check", "--", patch]) do
      {:ok, {_output, 0}} ->
        with :ok <- check_abort(signal) do
          case git_cmd(git, root, apply ++ ["--", patch]) do
            {:ok, {_output, 0}} -> :ok
            {:ok, {output, _}} -> {:conflict, conflicting_files(output)}
            {:error, reason} -> {:error, reason}
          end
        end

      {:ok, {output, _status}} ->
        {:conflict, conflicting_files(output)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Applies to the same parent checkout are serialized across concurrent children.
  defp serialized(root, fun), do: :global.trans({{__MODULE__, root}, self()}, fun, [node()])

  defp conflicting_files(output) do
    ~r/^error: (?:patch failed: (.+):\d+|(.+?): (?:patch does not apply|already exists in working directory|does not exist in index|No such file or directory))$/m
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.map(fn captures -> Enum.find(captures, &(&1 != "")) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> bounded_files()
  end

  defp commit_staged(_git, _prepared, [], _task_id, _description), do: {:ok, :nothing_staged}

  defp commit_staged(git, prepared, _files, task_id, description) do
    run_git(
      git,
      prepared.worktree_path,
      ["commit", "--no-verify", "-q", "-m", commit_message(task_id, description)],
      @identity
    )
  end

  defp commit_message(task_id, description) do
    summary =
      (description || "")
      |> String.replace(~r/[\x00-\x1f\x7f]+/u, " ")
      |> String.trim()
      |> String.slice(0, 72)

    if summary == "", do: "lemon task #{task_id}", else: "lemon task #{task_id}: #{summary}"
  rescue
    _ in [ArgumentError] -> "lemon task #{task_id}"
  end

  defp finalize_branch(git, root, prepared, "0"), do: no_changes(git, root, prepared, "branch")

  defp finalize_branch(git, root, prepared, count) do
    case run_git(git, prepared.worktree_path, ["rev-parse", "HEAD"]) do
      {:ok, head} ->
        %{
          mode: "branch",
          status: "committed",
          branch: prepared.branch,
          head: head,
          base_commit: prepared.base_commit,
          commits: String.to_integer(count)
        }
        |> with_cleanup(remove_resources(git, root, prepared, false))

      {:error, reason} ->
        merge_error("branch", prepared, reason)
    end
  end

  defp no_changes(git, root, prepared, mode) do
    %{mode: mode, status: "no_changes"}
    |> with_cleanup(remove_resources(git, root, prepared, true))
  end

  defp remove_resources(git, root, prepared, delete_branch?) do
    worktree = run_git(git, root, ["worktree", "remove", "--force", "--", prepared.worktree_path])

    branch =
      if delete_branch?,
        do: run_git(git, root, ["branch", "-D", "--", prepared.branch]),
        else: {:ok, ""}

    match?({{:ok, _}, {:ok, _}}, {worktree, branch})
  end

  defp with_cleanup(merge, true), do: merge

  defp with_cleanup(merge, false),
    do: Map.put(merge, :cleanup_error, "Could not fully remove the task worktree resources")

  defp merge_error(mode, prepared, reason) do
    %{
      mode: mode,
      status: if(reason == "Task aborted", do: "skipped", else: "error"),
      reason: reason,
      worktree_path: prepared.worktree_path,
      branch: prepared.branch
    }
  end

  defp bounded_files(files) do
    files
    |> Enum.take(@max_listed_files)
    |> Enum.map(&truncate_path/1)
  end

  defp truncate_path(path) do
    if byte_size(path) > @max_path_bytes,
      do: binary_part(path, 0, @max_path_bytes) |> String.replace_invalid() |> Kernel.<>("…"),
      else: String.replace_invalid(path)
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  defp reserve_file(path) do
    case File.write(path, "", [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> {:error, "Task patch path already exists"}
      {:error, _} -> {:error, "Cannot reserve task patch path"}
    end
  end

  defp cleanup(git, root, path, branch, reason) do
    # Git cleans its registration on a failed add. If add succeeded but the
    # requested subdirectory is absent, remove that registration explicitly.
    run_git(git, root, ["worktree", "remove", "--force", "--", path])
    path_result = File.rm_rf(path)
    branch_result = run_git(git, root, ["branch", "-D", "--", branch])

    case {path_result, branch_result} do
      {{:ok, _}, {:ok, _}} -> {:error, reason}
      _ -> {:error, reason <> "; could not fully clean the task's new worktree resources"}
    end
  end

  defp run_git(git, cwd, args, config \\ []) do
    case git_cmd(git, cwd, args, config) do
      {:ok, {output, 0}} ->
        {:ok, String.trim_trailing(output, "\n")}

      {:ok, {_output, _status}} ->
        {:error, "Git #{Enum.take(args, 2) |> Enum.join(" ")} failed for the task worktree"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git_cmd(git, cwd, args, config \\ []) do
    # Do not run repository hooks that might copy local state into the child.
    # Git itself populates the checkout solely from the committed tree.
    options = ["-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false"] ++ config
    {:ok, System.cmd(git, options ++ args, cd: cwd, stderr_to_stdout: true)}
  rescue
    _ in [ErlangError, ArgumentError] ->
      {:error, "Could not execute Git for the task worktree"}
  end
end
