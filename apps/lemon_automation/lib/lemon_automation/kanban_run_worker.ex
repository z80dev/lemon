defmodule LemonAutomation.KanbanRunWorker do
  @moduledoc false

  alias LemonAutomation.{KanbanWorktree, RunCompletionWaiter}
  alias LemonCore.{Bus, Id, KanbanStore, SessionKey}

  @default_timeout_ms 300_000

  def run(task, opts \\ []) do
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    wait_opts = Keyword.get(opts, :wait_opts, [])
    run_id = Keyword.get(opts, :run_id, Id.run_id())

    with {:ok, workspace} <- prepare_workspace(task, opts) do
      topic = Bus.run_topic(run_id)
      Bus.subscribe(topic)

      params =
        build_params(
          task,
          run_id,
          Keyword.merge(opts, cwd: workspace.cwd, worktree: workspace.worktree)
        )

      try do
        submit_and_wait(router_mod, waiter_mod, params, run_id, topic, timeout_ms, wait_opts)
      rescue
        error ->
          {:error, Exception.message(error)}
      catch
        :exit, reason ->
          {:error, {:exit, reason}}
      after
        Bus.unsubscribe(topic)
      end
    end
  end

  defp submit_and_wait(router_mod, waiter_mod, params, run_id, topic, timeout_ms, wait_opts) do
    case router_mod.submit(params) do
      {:ok, ^run_id} ->
        case waiter_mod.wait_already_subscribed(run_id, timeout_ms, wait_opts) do
          {:ok, _result} -> {:ok, %{run_id: run_id}}
          :timeout -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end

      {:ok, other_run_id} ->
        Bus.unsubscribe(topic)

        case waiter_mod.wait(other_run_id, timeout_ms, wait_opts) do
          {:ok, _result} -> {:ok, %{run_id: other_run_id}}
          :timeout -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end

      {:error, reason} ->
        Bus.unsubscribe(topic)
        {:error, reason}

      other ->
        Bus.unsubscribe(topic)
        {:error, {:unexpected_submit_result, other}}
    end
  end

  def build_params(task, run_id \\ nil, opts \\ []) do
    board = KanbanStore.get_board(task.board_id)
    agent_id = task.assignee || Keyword.get(opts, :agent_id, "default")
    run_id = run_id || Id.run_id()
    worktree = Keyword.get(opts, :worktree)

    %{
      origin: :kanban,
      run_id: run_id,
      session_key: task.session_key || fork_session_key(agent_id),
      agent_id: agent_id,
      model: Keyword.get(opts, :model),
      prompt: prompt(task, board),
      cwd: Keyword.get(opts, :cwd) || board[:workspace],
      tool_policy: %{blocked_tools: ["kanban"]},
      meta:
        %{
          kanban_board_id: task.board_id,
          kanban_task_id: task.id,
          kanban_worker_profile: task.worker_profile,
          kanban_dispatcher: true
        }
        |> maybe_put_worktree_meta(worktree)
    }
  end

  defp prepare_workspace(task, opts) do
    worktree_mod = Keyword.get(opts, :worktree_mod, KanbanWorktree)
    board = KanbanStore.get_board(task.board_id)
    worktree_mod.prepare(task, board, opts)
  end

  defp maybe_put_worktree_meta(meta, nil), do: meta

  defp maybe_put_worktree_meta(meta, worktree) do
    meta
    |> Map.put(:kanban_worktree_path, worktree.path)
    |> Map.put(:kanban_worktree_branch, worktree.branch)
    |> Map.put(:kanban_worktree_root, worktree.root)
  end

  defp prompt(task, board) do
    """
    You are working on a durable Lemon kanban task.

    Board: #{board[:name] || task.board_id}
    Task: #{task.title}
    Priority: #{task.priority || "normal"}

    #{task.description || ""}

    Complete the task, then summarize what changed and any remaining blockers.
    """
  end

  defp fork_session_key(agent_id) do
    session_key = "agent:#{agent_id}:main:sub:kanban_#{Id.session_id()}"

    if SessionKey.valid?(session_key) do
      session_key
    else
      "agent:#{agent_id}:main"
    end
  rescue
    _ -> "agent:#{agent_id}:main"
  end
end
