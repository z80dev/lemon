defmodule LemonAutomation.KanbanRunWorker do
  @moduledoc """
  Runs one leased kanban card through the router.

  Work runs only under the board's recorded `LemonAutomation.KanbanAuthority`;
  a board without one is quarantined and nothing is submitted. The worker tool
  policy is that authority's policy intersected with the card's recorded
  creator/editor policies, and always blocks delegation tools that would not
  carry it (`kanban`, `goal`, `cron`). The execution directory is re-resolved
  against the authority root immediately before submission. A session is reused
  only when a lease-guarded dispatcher run recorded it for this exact card.
  """

  alias LemonAutomation.{KanbanAuthority, KanbanStore}
  alias LemonAutomation.{KanbanWorktree, RunCompletionWaiter}
  alias LemonCore.{Id, SessionKey, ToolPolicy}

  @default_timeout_ms 300_000

  def run(task, opts \\ []) do
    board = KanbanStore.get_board(task.board_id)

    with {:ok, _policy} <- effective_policy(task, board),
         {:ok, workspace} <- KanbanWorktree.prepare(task, board, opts) do
      config = get_in(board, [:meta, "codingWorkflow"])

      if config in [nil, false] and not is_map(task.meta["codingWorkflow"]) do
        run_coding(task, workspace, opts)
      else
        LemonAutomation.KanbanCodingWorkflow.run(task, workspace, config, opts)
      end
    end
  end

  @doc false
  def run_coding(task, workspace, opts) do
    run_id = Keyword.get(opts, :run_id, Id.run_id())

    with {:ok, params} <-
           build_params(
             task,
             run_id,
             Keyword.merge(opts, cwd: workspace.cwd, worktree: workspace.worktree)
           ),
         {:ok, params} <- bind_execution(params, workspace) do
      submit(params, task, workspace, opts)
    end
  rescue
    _error -> {:error, :worker_failed}
  catch
    :exit, _reason -> {:error, :worker_failed}
  end

  defp submit(params, task, workspace, opts) do
    case RunCompletionWaiter.submit_and_wait(params,
           router_mod: Keyword.get(opts, :router_mod, LemonRouter),
           waiter_mod: Keyword.get(opts, :waiter_mod, RunCompletionWaiter),
           bus_mod: Keyword.get(opts, :bus_mod, LemonCore.Bus),
           timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
           wait_opts: Keyword.get(opts, :wait_opts, []),
           on_submitting: submission_claim(opts, params, workspace, task)
         ) do
      {:ok, completed_run_id, output} ->
        {:ok, %{run_id: completed_run_id, output: output, session_key: params.session_key}}

      {:error, {state, id}}
      when state in [:timeout, :completion_outcome_unknown, :submission_outcome_unknown] ->
        {:outcome_unknown, id}

      {:error, {:unexpected_run_id, id, _other}} ->
        {:outcome_unknown, id}

      {:error, {:run_failed, _run_id, reason}} ->
        {:error, reason}

      {:error, {:submit_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp submission_claim(opts, params, workspace, task) do
    fn run_id ->
      with :ok <- LemonAutomation.RunNotifications.bind_kanban(task, params) do
        case Keyword.get(opts, :on_submitting) do
          callback when is_function(callback, 2) ->
            callback.(run_id, %{
              "sessionKey" => params.session_key,
              "cwd" => workspace.cwd,
              "branch" => workspace.worktree && workspace.worktree.branch
            })

          _ ->
            :ok
        end
      end
    end
  end

  @doc """
  Builds the router request for a card. Fails closed when the board has no
  recorded authority.

  `:trusted_session_key` lets the controller continue a session it recorded in
  its own lease-guarded workflow checkpoint; it is still bound to the agent.
  """
  def build_params(task, run_id \\ nil, opts \\ []) do
    board = KanbanStore.get_board(task.board_id)
    agent_id = task.assignee || Keyword.get(opts, :agent_id, "default")
    run_id = run_id || Id.run_id()
    worktree = Keyword.get(opts, :worktree)

    with {:ok, _policy} <- effective_policy(task, board) do
      {:ok,
       %{
         origin: :kanban,
         run_id: run_id,
         session_key: worker_session_key(task, agent_id, opts),
         agent_id: agent_id,
         model: Keyword.get(opts, :model),
         prompt: Keyword.get(opts, :prompt, prompt(task, board)),
         cwd: Keyword.get(opts, :cwd) || board[:workspace],
         tool_policy: confine(%{}, task),
         meta:
           %{
             kanban_board_id: task.board_id,
             kanban_task_id: task.id,
             kanban_worker_profile: task.worker_profile,
             kanban_dispatcher: true
           }
           |> maybe_put_worktree_meta(worktree)
       }}
    end
  end

  @doc """
  The card's recorded authority: the board authority policy intersected with
  every card creator/editor policy. Missing or malformed authority fails closed.
  """
  @spec effective_policy(map(), map() | nil) ::
          {:ok, ToolPolicy.t()} | {:error, :kanban_authority_missing}
  def effective_policy(task, board \\ nil) do
    board = board || KanbanStore.get_board(task.board_id)

    with {:ok, authority} <- KanbanAuthority.fetch(board),
         {:ok, policy} <- card_policy(KanbanAuthority.policy(authority), task) do
      {:ok, policy}
    else
      _ -> {:error, :kanban_authority_missing}
    end
  end

  defp card_policy(policy, task) do
    case get_in(task, [:meta, "dispatchPolicy"]) do
      nil -> {:ok, policy}
      card -> ToolPolicy.restrict(policy, card)
    end
  end

  @doc """
  Confines a worker or reviewer run policy to the card's recorded authority and
  blocks delegation tools that would not carry it. Without authority the result
  denies every tool.
  """
  def confine(policy, task) do
    case effective_policy(task) do
      {:ok, recorded} ->
        policy
        |> ToolPolicy.intersect(ToolPolicy.to_map(recorded))
        |> ToolPolicy.intersect(%{blocked_tools: KanbanAuthority.delegation_tools()})

      {:error, _} ->
        Map.from_struct(ToolPolicy.deny_all())
    end
  end

  @doc """
  Binds a request to the prepared execution directory: the path must still
  resolve canonically to the same `{dev, inode}` object, and the identity is
  passed as `meta.cwd_identity` for the session runner to re-verify when the
  session actually starts and before every tool call. `meta.mutation_root`
  confines the session's file-mutation tools (write, edit, patch, ast_grep
  rewrites, archive/SQLite writes, LSP edits) to that directory, so a worker
  cannot write controller metadata or anything else outside it.
  """
  def bind_execution(params, %{cwd: cwd, identity: identity}) when is_map(identity) do
    with {:ok, ^cwd} <- KanbanAuthority.canonical_directory(cwd),
         {:ok, ^identity} <- KanbanAuthority.directory_identity(cwd),
         true <- params.cwd == cwd do
      {:ok,
       params
       |> put_in([:meta, :cwd_identity], identity)
       |> put_in([:meta, :mutation_root], cwd)}
    else
      _ -> {:error, :workspace_changed}
    end
  end

  def bind_execution(_params, _workspace), do: {:error, :workspace_changed}

  defp worker_session_key(task, agent_id, opts) do
    prefix = "agent:#{agent_id}:main:sub:kanban_"

    [Keyword.get(opts, :trusted_session_key), KanbanStore.trusted_run_session(task)]
    |> Enum.find(&(is_binary(&1) and String.starts_with?(&1, prefix)))
    |> case do
      nil -> fork_session_key(agent_id)
      session_key -> session_key
    end
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
