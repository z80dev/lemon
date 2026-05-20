defmodule LemonAutomation.KanbanWorktree do
  @moduledoc false

  @type context :: %{
          cwd: binary() | nil,
          worktree: map() | nil
        }

  @spec prepare(map(), map() | nil, keyword()) :: {:ok, context()} | {:error, term()}
  def prepare(task, board, opts \\ []) do
    mode = Keyword.get(opts, :worktree_mode, :auto)
    workspace = Keyword.get(opts, :cwd) || board_workspace(board)

    cond do
      mode in [false, :off, "off"] ->
        {:ok, %{cwd: workspace, worktree: nil}}

      not is_binary(workspace) or workspace == "" ->
        {:ok, %{cwd: workspace, worktree: nil}}

      true ->
        maybe_prepare(task, workspace, mode, opts)
    end
  end

  defp maybe_prepare(task, workspace, mode, opts) do
    case git_root(workspace) do
      {:ok, repo} ->
        path = Keyword.get(opts, :worktree_path) || default_path(repo, task)
        branch = Keyword.get(opts, :worktree_branch) || default_branch(task)

        with :ok <- ensure_worktree(repo, path, branch) do
          {:ok,
           %{
             cwd: path,
             worktree: %{
               root: repo,
               path: path,
               branch: branch,
               mode: :git_worktree
             }
           }}
        end

      {:error, reason} when mode in [:auto, "auto"] ->
        {:ok, %{cwd: workspace, worktree: nil, skipped: reason}}

      {:error, reason} ->
        {:error, {:worktree_unavailable, reason}}
    end
  end

  defp ensure_worktree(repo, path, branch) do
    cond do
      worktree?(path) ->
        :ok

      File.exists?(path) ->
        {:error, {:path_exists, path}}

      true ->
        File.mkdir_p!(Path.dirname(path))
        add_worktree(repo, path, branch)
    end
  end

  defp add_worktree(repo, path, branch) do
    args =
      if branch_exists?(repo, branch) do
        ["worktree", "add", path, branch]
      else
        ["worktree", "add", "-b", branch, path, "HEAD"]
      end

    case git(repo, args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:git_worktree_add_failed, reason}}
    end
  end

  defp branch_exists?(repo, branch) do
    case git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp git_root(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, %{code: code, output: String.trim(output)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, %{code: code, output: String.trim(output)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp worktree?(path) do
    File.exists?(Path.join(path, ".git"))
  end

  defp default_path(repo, task) do
    Path.join([repo, ".worktrees", "kanban-#{slug(task_id(task))}"])
  end

  defp default_branch(task) do
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
