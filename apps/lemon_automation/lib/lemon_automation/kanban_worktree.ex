defmodule LemonAutomation.KanbanWorktree do
  @moduledoc """
  Creates task-owned isolated Git worktrees of the board's controller-owned
  repository (`LemonAutomation.KanbanGitSandbox`). Reuse requires the
  controller repository's own records (registered path, administrative
  directory and branch); a worktree's `.git` file is never evidence of
  ownership.

  Every preparation (first dispatch and every recovery) re-resolves the board's
  recorded canonical workspace against its authority root: a component replaced
  by a symlink fails as `:workspace_changed`, and a repository top level outside
  the root as `:worktree_outside_authorized_root` (a subdirectory workspace is
  never promoted to its parent repository).

  A fresh worktree starts from the workspace repository's `HEAD`, fetched into
  the controller repository with `git fetch --no-tags <workspace> HEAD`;
  nothing is checked out, staged or committed in the workspace repository.
  Worktrees live in a Lemon-owned directory (`~/.lemon/kanban/worktrees`),
  outside the caller's workspace root, created by the controller with no
  symlink components. The prepared context carries the execution directory's
  `{dev, inode}` identity; the worker passes it as `meta.cwd_identity` and the
  session runner refuses to start a session in any other directory object.
  """

  alias LemonAutomation.KanbanAuthority
  alias LemonAutomation.{KanbanGitSandbox, KanbanGitWorkflow}

  @type context :: %{
          cwd: binary() | nil,
          worktree: map() | nil,
          identity: map()
        }

  @spec prepare(map(), map() | nil, keyword()) :: {:ok, context()} | {:error, term()}
  def prepare(task, board, opts \\ []) do
    mode = Keyword.get(opts, :worktree_mode, :auto)

    with true <- own_id(board) == board_id(task) or {:error, :invalid_board},
         {:ok, authority} <- KanbanAuthority.fetch(board || %{}),
         {:ok, workspace} <- KanbanAuthority.check_workspace(authority, board_workspace(board)),
         {:ok, context} <-
           if(mode in [false, :off, "off"],
             do: in_place(workspace, authority, nil),
             else: maybe_prepare(task, workspace, authority, mode, opts)
           ),
         {:ok, identity} <- KanbanAuthority.directory_identity(context.cwd) do
      {:ok, Map.put(context, :identity, identity)}
    end
  end

  defp maybe_prepare(task, workspace, authority, mode, opts) do
    case git_root(workspace, opts) do
      {:ok, repo} ->
        branch = Keyword.get(opts, :worktree_branch) || branch_for(task)

        with :ok <- contained(repo, authority),
             {:ok, base} <- owned_base(authority),
             {:ok, git_dir} <- controller_path(task),
             :ok <- outside_root(git_dir, authority),
             path = Keyword.get(opts, :worktree_path) || Path.join(base, worktree_name(task)),
             :ok <- owned_location(path, base),
             :ok <- ensure_worktree(task, git_dir, repo, path, branch, opts),
             {:ok, ^path} <- KanbanAuthority.canonical_directory(path) do
          {:ok,
           %{
             cwd: path,
             worktree: %{
               root: repo,
               path: path,
               branch: branch,
               git_dir: git_dir,
               mode: :git_worktree
             }
           }}
        else
          {:ok, _other} -> {:error, :workspace_changed}
          {:error, _} = error -> error
        end

      # Only "not inside a repository" falls back; sandbox failures fail closed.
      {:error, :git_failed = reason} when mode in [:auto, "auto"] ->
        in_place(workspace, authority, reason)

      {:error, reason} ->
        {:error, {:worktree_unavailable, reason}}
    end
  end

  # Running in the caller's own directory needs an explicit operator grant for
  # exactly this workspace: the caller can replace or rewrite it at any time.
  defp in_place(workspace, authority, skipped) do
    if KanbanAuthority.in_place_granted?(authority, workspace),
      do: {:ok, %{cwd: workspace, worktree: nil, skipped: skipped}},
      else: {:error, :in_place_execution_not_authorized}
  end

  # The repository top level must itself lie inside the authorized root.
  defp contained(repo, authority) do
    case KanbanAuthority.canonical_directory(repo) do
      {:ok, ^repo} ->
        if KanbanAuthority.within?(repo, authority["root"]),
          do: :ok,
          else: {:error, :worktree_outside_authorized_root}

      _ ->
        {:error, :worktree_outside_authorized_root}
    end
  end

  # The Lemon-owned base must not be reachable from (or contain) the root.
  defp owned_base(authority) do
    with {:ok, base} <- base(),
         :ok <- outside_root(base, authority),
         do: {:ok, base}
  end

  defp outside_root(path, authority) do
    if KanbanAuthority.within?(path, authority["root"]) or
         KanbanAuthority.within?(authority["root"], path),
       do: {:error, :worktree_base_inside_root},
       else: :ok
  end

  defp owned_location(path, base) do
    if is_binary(path) and path == Path.expand(path) and Path.dirname(path) == base,
      do: :ok,
      else: {:error, :invalid_worktree}
  end

  # Canonical, controller-created `~/.lemon/kanban/worktrees` (no symlink
  # components below the resolved state directory).
  defp base do
    path = LemonCore.Paths.home_path(["kanban", "worktrees"])

    with :ok <- File.mkdir_p(path),
         {:ok, base} <- KanbanAuthority.canonical_directory(path),
         true <- KanbanGitWorkflow.clean_path?(base) do
      {:ok, base}
    else
      _ -> {:error, :worktree_base_unavailable}
    end
  end

  defp ensure_worktree(task, git_dir, repo, path, branch, opts) do
    git_opts = Keyword.take(opts, [:runner, :task_supervisor])

    cond do
      File.exists?(path) ->
        with :ok <- KanbanGitSandbox.verify_controller(git_dir),
             do: KanbanGitWorkflow.validate_context(git_dir, path, branch, git_opts)

      not safe_destination?(path) ->
        {:error, :invalid_worktree}

      true ->
        with {:ok, ^git_dir} <- KanbanGitSandbox.ensure_controller(board_id(task), git_opts),
             :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- add_worktree(task, git_dir, repo, path, branch, git_opts) do
          KanbanGitWorkflow.validate_context(git_dir, path, branch, git_opts)
        end
    end
  end

  # A new branch starts at the workspace repository's HEAD, fetched as data
  # (objects only) into the controller repository.
  defp add_worktree(task, git_dir, repo, path, branch, opts) do
    controller = %{git_dir: git_dir, common_dir: git_dir, work_tree: nil}
    base_ref = "refs/lemon/base/" <> slug(task_id(task))

    result =
      if branch_exists?(controller, branch, opts) do
        KanbanGitWorkflow.controller_git(controller, ["worktree", "add", path, branch], opts)
      else
        fetch = [
          "fetch",
          "--quiet",
          "--no-tags",
          "--no-write-fetch-head",
          "--no-recurse-submodules",
          "--no-auto-maintenance",
          "--",
          repo,
          "+HEAD:" <> base_ref
        ]

        with {:ok, _} <-
               KanbanGitWorkflow.controller_git(
                 controller,
                 fetch,
                 Keyword.put(opts, :allowed_protocols, ["file"])
               ) do
          KanbanGitWorkflow.controller_git(
            controller,
            ["worktree", "add", "-b", branch, path, base_ref],
            opts
          )
        end
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:git_worktree_add_failed, reason}}
    end
  end

  defp branch_exists?(controller, branch, opts) do
    case KanbanGitWorkflow.controller_git(
           controller,
           ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
           opts
         ) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp git_root(workspace, opts) do
    with {:ok, root} <-
           KanbanGitWorkflow.git(
             workspace,
             ["rev-parse", "--show-toplevel"],
             Keyword.take(opts, [:runner, :task_supervisor])
           ),
         root = String.trim(root),
         true <- KanbanGitWorkflow.clean_path?(root) do
      {:ok, root}
    else
      false -> {:error, :invalid_worktree}
      {:error, _} = error -> error
    end
  end

  defp safe_destination?(path) when is_binary(path) do
    path == Path.expand(path) and safe_parent?(Path.dirname(path)) and
      match?({:error, :enoent}, File.lstat(path))
  end

  defp safe_destination?(_), do: false

  defp safe_parent?(path) do
    case File.lstat(path) do
      {:error, :enoent} -> safe_parent?(Path.dirname(path))
      {:ok, %{type: :directory}} -> KanbanGitWorkflow.clean_path?(path)
      _ -> false
    end
  end

  @doc false
  def path_for(task) do
    with {:ok, base} <- base(), do: {:ok, Path.join(base, worktree_name(task))}
  end

  @doc "The board's controller repository for `task` (`task.board_id`)."
  def controller_path(task), do: KanbanGitSandbox.controller_path(board_id(task))

  defp board_id(%{board_id: id}), do: id
  defp board_id(%{"board_id" => id}), do: id
  defp board_id(_), do: nil

  defp own_id(%{id: id}), do: id
  defp own_id(%{"id" => id}), do: id
  defp own_id(_), do: nil

  defp worktree_name(task), do: "kanban-#{slug(task_id(task))}"

  @doc false
  def branch_for(task) do
    "lemon-kanban/#{slug(task_id(task))}"
  end

  defp task_id(%{id: id}) when is_binary(id), do: id
  defp task_id(%{"id" => id}) when is_binary(id), do: id
  defp task_id(_), do: "task"

  defp board_workspace(%{workspace: workspace}), do: workspace
  defp board_workspace(%{"workspace" => workspace}), do: workspace
  defp board_workspace(_), do: nil

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "task"
      slug -> String.slice(slug, 0, 80)
    end
  end
end
