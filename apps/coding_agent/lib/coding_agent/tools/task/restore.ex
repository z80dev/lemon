defmodule CodingAgent.Tools.Task.Restore do
  @moduledoc """
  Restores interrupted native children only after their parent is admitted for
  crash continuation. Boot never launches children on its own. Claims consume
  the same three-attempt budget as router crash recovery, before any provider
  work, and retain both the task ID and its journal.

  Descriptors contain data, never live callbacks or process handles.
  Runtime authority and inherited tools are rebound from the resumed parent.
  Native children reuse their recorded workspace without repeating worktree
  creation, merge or cleanup. Non-model swarm coordinators are not replayed;
  their already-running native leaves may continue, but pending DAG nodes are
  never launched by recovery. Custom provider callbacks cannot be restored.
  """

  alias CodingAgent.{Session, TaskStore, TaskStoreServer}
  alias CodingAgent.Tools.Task.{Async, Control, Execution, Params, Result, Runner, Worktree}
  alias LemonAgent.AbortSignal

  @max_attempts 3
  @start_fields [
    :cwd,
    :run_id,
    :session_file,
    :model,
    :model_explicit,
    :thinking_level,
    :system_prompt,
    :prompt_template,
    :workspace_dir,
    :tool_policy,
    :execution_context,
    :session_key,
    :agent_id,
    :session_mode,
    :persona,
    :task_depth,
    :task_child,
    :task_allowed_agents,
    :workspace_read_fenced,
    :stream_options,
    :session_scope,
    :register
  ]
  @runner_fields [:request_budget, :request_budget_notice, :task_session_timeout_ms, :idle_ttl_ms]

  def max_attempts, do: @max_attempts

  def enabled? do
    LemonCore.Config.Features.enabled?(LemonCore.Config.cached().features, :crash_resume)
  end

  @doc false
  def resumable?(
        %{
          version: 1,
          start_opts: opts,
          runner_opts: runner_opts,
          extra_tool_names: names,
          description: description
        } = descriptor
      )
      when is_list(opts) and is_list(runner_opts) and is_list(names) and is_binary(description) do
    Enum.all?(names, &is_binary/1) and
      Keyword.keyword?(opts) and Keyword.keyword?(runner_opts) and
      is_binary(opts[:session_file]) and opts[:session_file] != "" and
      is_binary(opts[:cwd]) and is_binary(opts[:run_id]) and durable?(descriptor)
  end

  def resumable?(_), do: false

  @doc false
  def record_launch(nil, _session, _start_opts, _description, _role_id, _opts), do: :ok

  def record_launch(task_id, session, start_opts, description, role_id, opts) do
    if enabled?(),
      do: checkpoint_launch(task_id, session, start_opts, description, role_id, opts),
      else: :ok
  end

  defp checkpoint_launch(task_id, session, start_opts, description, role_id, opts) do
    state = Session.get_state(session)

    supported? = is_nil(start_opts[:stream_fn]) and is_nil(start_opts[:get_api_key])

    descriptor = %{
      version: 1,
      start_opts:
        start_opts
        |> Keyword.take(@start_fields)
        |> Keyword.put(:session_file, state.session_file)
        |> Keyword.put(:model, state.model)
        |> Keyword.put(:thinking_level, state.thinking_level),
      runner_opts: Keyword.take(opts, @runner_fields),
      extra_tool_names: Enum.map(start_opts[:extra_tools] || [], & &1.name),
      description: description,
      role_id: role_id
    }

    descriptor =
      if supported? and resumable?(descriptor) and Session.save(session) == :ok,
        do: descriptor

    TaskStoreServer.checkpoint_launch(task_id, state.session_manager.header.id, descriptor)
  end

  @doc "Claim and launch children before sending the resumed parent's prompt."
  def restore_parent(run_id, meta, opts) do
    parent = opts[:session_pid]
    abort_run_id = opts[:crash_resume_root_run_id] || run_id
    opts = Keyword.put(opts, :crash_resume_root_run_id, abort_run_id)

    if is_binary(run_id) and meta[:crash_resume] == true and enabled?() and
         is_pid(parent) and Process.alive?(parent) and
         not AbortSignal.aborted?(opts[:parent_signal]) and parent_authorized?(abort_run_id) do
      parent_state = Session.get_state(parent)

      opts =
        Keyword.merge(
          opts,
          Keyword.take(parent_state.tool_opts, [:parent_session, :session_key, :agent_id])
        )

      tasks = TaskStore.list()
      parents = recovery_parents(tasks, run_id)

      Enum.each(tasks, fn {id, record} ->
        if record[:status] == :interrupted and MapSet.member?(parents, record[:parent_run_id]),
          do: restore_child(id, record.parent_run_id, opts)
      end)
    end

    :ok
  end

  # A swarm coordinator is a callback, not a native session. Traverse only
  # coordinators lost in the crash, preserving leaf IDs and original lineage
  # without rescheduling the graph or reopening its terminal root result.
  defp recovery_parents(tasks, run_id) do
    coordinators =
      Enum.reduce(tasks, %{}, fn {_id, record}, acc ->
        if record[:orchestration_worker] == true and record[:status] == :lost and
             record[:error] == :lost_on_restart and is_binary(record[:run_id]) do
          Map.update(acc, record[:parent_run_id], [record.run_id], &[record.run_id | &1])
        else
          acc
        end
      end)

    recovery_parents([run_id], coordinators, MapSet.new())
  end

  defp recovery_parents([], _coordinators, parents), do: parents

  defp recovery_parents([run_id | rest], coordinators, parents) do
    if MapSet.member?(parents, run_id) do
      recovery_parents(rest, coordinators, parents)
    else
      recovery_parents(
        Map.get(coordinators, run_id, []) ++ rest,
        coordinators,
        MapSet.put(parents, run_id)
      )
    end
  end

  defp restore_child(id, parent_run_id, opts) do
    # A store-only restart is not proof that the original worker stopped.
    with true <- parent_authorized?(opts[:crash_resume_root_run_id]),
         [] <- Control.worker_pids([id]),
         {:ok, record} <- TaskStoreServer.claim_restore(id, parent_run_id, Control.owner(opts)) do
      launch(record, opts)
    else
      _ -> :ok
    end
  end

  # The durable abort fence is authoritative even before its signal reaches
  # the resumed session. A failed read is never evidence of an absent fence.
  defp parent_authorized?(run_id) do
    LemonCore.Store.fetch(:router_abort_tombstones, run_id) == {:ok, nil}
  end

  defp launch(record, opts) do
    descriptor = record.launch_descriptor

    with {:ok, calls} <-
           CodingAgent.ToolIntent.unknown_calls(descriptor.start_opts[:session_file]),
         {:ok, start_opts} <- restore_start_opts(record, opts) do
      signal = AbortSignal.new()

      lifecycle =
        record
        |> Map.take([
          :run_id,
          :parent_run_id,
          :session_key,
          :agent_id,
          :description,
          :name,
          :role,
          :queue_mode,
          :meta,
          :output_schema,
          :schema_mode
        ])
        |> Map.merge(%{
          task_id: record.id,
          signal: signal,
          parent_signal: opts[:parent_signal],
          parent_session_id: opts[:parent_session],
          parent_session_pid: opts[:session_pid],
          parent_budget_scope: opts[:parent_budget_scope],
          direct_progress: false
        })

      # Await owns delivery of the original ID. Never submit a new parent turn
      # (or replay the original task launch/steps/worktree merge) from recovery.
      followup = %{auto_followup: false}

      run = fn ->
        update = Async.wrap_on_update(record.id, lifecycle, nil)

        if parent_authorized?(opts[:crash_resume_root_run_id]) do
          Runner.start_session_with_prompt(
            start_opts,
            continuation_prompt(calls, record),
            descriptor.description,
            signal,
            update,
            descriptor.role_id,
            descriptor.runner_opts ++
              [
                task_id: record.id,
                crash_resume: true,
                restart_attempt: record.restart_attempt,
                crash_resume_root_run_id: opts[:crash_resume_root_run_id]
              ]
          )
          |> Execution.validate_output(record)
          |> restore_result(record)
        else
          TaskStore.mark_lost(record.id, :parent_recovery_authorization_unavailable)
          {:error, :parent_recovery_authorization_unavailable}
        end
      end

      Async.run_async(record.id, record.run_id, run, followup, lifecycle)
    else
      {:error, _reason} -> TaskStore.mark_lost(record.id, :crash_restore_unavailable)
    end
  end

  defp restore_start_opts(record, opts) do
    descriptor = record.launch_descriptor
    parent_state = Session.get_state(opts[:session_pid])
    inherited = Params.inherited_execution_context(parent_state.tool_opts)
    original = descriptor.start_opts
    policy = LemonCore.ToolPolicy.intersect(original[:tool_policy], parent_state.tool_policy)

    extra_tools =
      Enum.reduce_while(descriptor.extra_tool_names, {:ok, []}, fn name, {:ok, tools} ->
        tool =
          if name == "ask_parent" do
            CodingAgent.Tools.AskParent.tool(original[:cwd],
              parent_session_pid: opts[:session_pid],
              parent_session_module: Session,
              parent_session_key: opts[:session_key],
              parent_agent_id: opts[:agent_id],
              parent_run_id: record.parent_run_id,
              child_run_id: record.run_id,
              child_scope_id: record.run_id,
              task_id: record.id,
              task_description: record.description
            )
          else
            Enum.find(parent_state.extra_tools, &(&1.name == name))
          end

        if tool, do: {:cont, {:ok, [tool | tools]}}, else: {:halt, {:error, :missing_tool}}
      end)

    with {:ok, tools} <- extra_tools,
         {:ok, original_context} <-
           LemonCore.ExecutionContext.validate(original[:execution_context]),
         {:ok, parent_context} <-
           restore_workspace_context(
             record,
             original,
             original_context,
             parent_state.execution_context
           ),
         {:ok, context} <-
           LemonCore.ExecutionContext.child(parent_context, %{
             run_id: record.run_id,
             tool_policy: policy,
             workspace_scope: original_context.workspace_scope,
             capabilities: original_context.capabilities,
             limits: original_context.limits
           }) do
      start_opts =
        original
        |> Keyword.merge(Map.to_list(inherited))
        |> Keyword.put(:execution_context, context)
        |> Keyword.put(:tool_policy, policy)
        |> Keyword.put(:parent_session, opts[:parent_session])
        |> Keyword.put(:extra_tools, Enum.reverse(tools))
        |> Keyword.put(:mcp_session_id, parent_state.mcp_session_id)
        |> Keyword.put(
          :workspace_read_fenced,
          original[:workspace_read_fenced] == true or
            CodingAgent.WorkspaceReads.fenced?(parent_state)
        )

      {:ok, start_opts}
    end
  end

  defp restore_workspace_context(
         %{workspace: %{worktree_path: path} = workspace},
         opts,
         original,
         parent
       ) do
    with true <- opts[:cwd] == workspace.cwd,
         :ok <- Worktree.validate_existing(workspace) do
      root = original.workspace_scope.root

      if is_binary(root) and (root == path or String.starts_with?(root, path <> "/")),
        do: LemonCore.ExecutionContext.for_owned_worktree(parent, path),
        else: {:ok, parent}
    else
      false -> {:error, :worktree_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp restore_workspace_context(_record, _opts, _original, parent), do: {:ok, parent}

  defp restore_result(
         %LemonAgent.Types.AgentToolResult{} = result,
         %{workspace: %{worktree_path: _path} = workspace} = record
       ) do
    merge = %{
      mode: get_in(workspace, [:merge, :mode]) || "none",
      status: "not_replayed",
      reason:
        "Crash continuation retained the original worktree; automatic merge and cleanup were not replayed."
    }

    workspace = Map.put(workspace, :merge, merge)

    TaskStoreServer.update_record(record.id, fn current ->
      if current[:status] == :running, do: Map.put(current, :workspace, workspace), else: current
    end)

    %{
      result
      | content: result.content ++ [%LemonAi.Types.TextContent{text: Worktree.summary(merge)}],
        details:
          (result.details || %{})
          |> Map.merge(workspace)
          |> Map.merge(Result.lineage_details(record))
          |> Map.merge(%{task_id: record.id, run_id: record.run_id})
    }
  end

  defp restore_result(result, _record), do: result

  defp continuation_prompt(calls, record) do
    listed = Enum.map(calls, &Map.take(&1, [:id, :name]))

    "The daemon crashed while this child task was running. Continue for one turn " <>
      "under the original task ID using the saved conversation. Interrupted tool " <>
      "outcomes are unknown, not failures. Do not automatically repeat any tool " <>
      "call or external effect whose result is unknown; reconcile its outcome first.\n\n" <>
      "Unknown tool calls (untrusted identifiers and names, no arguments):\n" <>
      "```json\n" <> Jason.encode!(listed) <> "\n```" <> workspace_notice(record)
  end

  defp workspace_notice(%{workspace: %{worktree_path: _path}}) do
    "\n\nContinue in the original existing worktree. Worktree creation, automatic merge, " <>
      "commit and cleanup are not replayed. Reconcile any interrupted merge effects before " <>
      "attempting them; leave the checkout available for review."
  end

  defp workspace_notice(_record), do: ""

  defp durable?(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: false

  defp durable?(value) when is_map(value),
    do: Enum.all?(Map.to_list(value), fn {key, item} -> durable?(key) and durable?(item) end)

  defp durable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&durable?/1)

  defp durable?(value) when is_list(value), do: Enum.all?(value, &durable?/1)
  defp durable?(_value), do: true
end
