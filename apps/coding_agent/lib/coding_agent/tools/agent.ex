defmodule CodingAgent.Tools.Agent do
  @moduledoc """
  Agent delegation tool.

  This tool submits work to another Lemon agent and can either:
  - return immediately with a `task_id` (`async=true`, default), or
  - wait for completion and return the delegated answer (`async=false`).

  Async runs can use `action=poll` to check status and `action=join` to wait
  for results; both are limited to tasks submitted by the calling session and
  agent (other task ids read as unknown). Join returns child answers in its
  content. Async runs can optionally auto-follow up into the current session
  when the delegated run completes. A submission whose outcome is unknown is
  tracked as `tracking_lost` under its fixed run id and never resubmitted.

  ## Bounds

  - Slots: a synchronous run or join lends the calling run's gateway permit
    (`LemonGateway.Slots.suspend/2`) while it blocks and takes it back at the
    front of the queue afterwards, so parents waiting on children (or a
    delegation chain) never hold the capacity their children need.
  - Deadline: synchronous runs and joins wait at most `timeout_ms` (default
    120000). A synchronous run that times out is aborted.
  - Budget: `CodingAgent.BudgetEnforcer` refuses a delegation when the
    parent's budget is exhausted or its child limit is reached, reserves the
    child against the parent, and sends the child's token/cost limits with the
    request so the child session stops when it exceeds them. The child's
    reported usage is charged to the parent on completion.
  - Cancellation: aborting the run that delegated (or a synchronous timeout)
    aborts the child through the run orchestrator (`RouterBridge.abort_run/2`);
    the child then emits its own terminal event.
  """

  require Logger

  alias CodingAgent.AsyncFollowups

  alias CodingAgent.{
    BudgetEnforcer,
    ModelProvenance,
    RunGraph,
    SettingsManager,
    Subagents,
    TaskStore
  }

  alias CodingAgent.Tools.Task.{Control, Params, Result}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.{Bus, Events, RouterBridge, RunRequest, SessionKey, Store}

  @valid_actions ["run", "poll", "join"]
  # Model-selectable submission and completion queues. `interrupt` aborts a
  # running conversation, so it is reachable only through trusted operator
  # config (`config :coding_agent, :async_followups, default_queue_mode: ...`).
  @valid_queue_modes ["collect", "followup", "steer", "steer_backlog"]
  @default_sync_timeout_ms 120_000
  @default_watcher_timeout_ms 30 * 60 * 1000
  @default_reconciliation_timeout_ms 30 * 60 * 1000
  @default_abort_grace_ms 30_000
  @default_run_orchestrator RouterBridge

  @doc """
  Returns the agent delegation tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    config_cwd = Keyword.get(opts, :config_cwd) || cwd
    agent_id_property = build_agent_id_property(config_cwd, opts)
    role_property = build_role_property(config_cwd)

    %AgentTool{
      name: "agent",
      timeout_ms: :infinity,
      description: build_description(),
      label: "Delegate To Agent",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" => "Default: run"
          },
          "agent_id" => agent_id_property,
          "prompt" => %{
            "type" => "string",
            "description" => "Delegated assignment"
          },
          "role" => role_property,
          "description" => %{
            "type" => "string",
            "description" => "Short tracking label"
          },
          "async" => %{
            "type" => "boolean",
            "description" => "Default/recommended true: return receipt immediately; false waits"
          },
          "auto_followup" => %{
            "type" => "boolean",
            "description" => "Default true: forward completion into this session"
          },
          "continue_session" => %{
            "type" => "boolean",
            "description" => "Default true: reuse the deterministic delegated session"
          },
          "queue_mode" => %{
            "type" => "string",
            "enum" => @valid_queue_modes,
            "description" => "Submission queue; default collect"
          },
          "followup_queue_mode" => %{
            "type" => "string",
            "enum" => @valid_queue_modes,
            "description" => "Completion queue; default configured mode or followup"
          },
          "tool_policy" => %{
            "type" => "object",
            "description" => "Delegated tool policy"
          },
          "cwd" => %{
            "type" => "string",
            "description" =>
              "Working directory; defaults to current cwd locally, destination cwd remotely"
          },
          "node" => %{
            "type" => "string",
            "description" =>
              "Execution node; omit or local for this node. Remote nodes use destination credentials"
          },
          "meta" => %{
            "type" => "object",
            "description" => "Delegated request metadata"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Synchronous run or join wait timeout; default 120000"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Poll target or single join target"
          },
          "task_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Join targets"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["wait_all", "wait_any"],
            "description" => "Join mode; default wait_all"
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
    # Present only while [runtime.task].per_call_model is on.
    |> Params.put_per_call_model_params(
      cwd,
      opts,
      ["model"],
      "omit to use the delegated defaults"
    )
  end

  @doc """
  Execute the agent delegation tool.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      case normalize_action(Map.get(params, "action")) do
        "poll" ->
          with :ok <- authorize_task_ids([Map.get(params, "task_id")], opts), do: do_poll(params)

        "join" ->
          do_join(params, signal, opts)

        "run" ->
          do_run(params, signal, cwd, opts)

        other ->
          {:error, "Unsupported action: #{inspect(other)}"}
      end
    end
  end

  defp do_run(params, signal, cwd, opts) do
    opts =
      Keyword.merge(
        opts,
        Map.to_list(Params.inherited_execution_context(opts))
      )

    with :ok <- Params.check_per_call_model(Map.take(params, ["model"]), cwd, opts),
         {:ok, validated} <- validate_run_params(params, cwd, opts),
         {:ok, delegated_session_key} <- resolve_delegated_session_key(validated, opts),
         :ok <- check_spawn_budget(opts),
         {:ok, request} <- build_run_request(validated, delegated_session_key, cwd, opts),
         {:ok, request} <- reserve_child(request, validated, delegated_session_key, opts) do
      # The run that delegated owns the child's lifetime and budget: its abort
      # signal cancels the child and the child's usage is charged to it.
      opts =
        opts
        |> Keyword.put_new(:cwd, cwd)
        |> Keyword.put(:delegation, %{
          signal: signal,
          reservation: request.run_id,
          parent_scope: parent_budget_scope(opts)
        })

      case submit_run(request, opts) do
        {:ok, run_id} when validated.async ->
          handle_async_submission(run_id, validated, delegated_session_key, request, opts)

        {:ok, run_id} ->
          wait_sync_completion(run_id, validated, delegated_session_key, signal, opts)

        {:error, :outcome_unknown} ->
          handle_unknown_submission(request, validated, delegated_session_key, opts)

        {:error, reason} = error ->
          release_child(request.run_id, {:submission_failed, reason})
          error
      end
    end
  end

  # Task ids are scoped to the submitting session and agent, exactly like the
  # `task` tool; foreign ids are indistinguishable from missing ones.
  defp authorize_task_ids(ids, opts) do
    Enum.reduce_while(ids, :ok, fn
      id, :ok when is_binary(id) ->
        case Control.authorize(id, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _id, :ok ->
        {:cont, :ok}
    end)
  end

  defp do_poll(params) do
    task_id = Map.get(params, "task_id") |> normalize_optional_string()

    if is_binary(task_id) do
      case ensure_latest_task_state(task_id) do
        {:ok, record, _events} ->
          with %AgentToolResult{details: details} = result <-
                 Result.do_get(%{"task_id" => task_id}) do
            agent_details =
              %{
                node: Map.get(record, :node, "local"),
                agent_id: Map.get(record, :agent_id),
                session_key: Map.get(record, :delegated_session_key),
                role: Map.get(record, :role)
              }
              |> compact_map()

            %{result | details: Map.merge(details, agent_details)}
          end

        {:error, :not_found} ->
          {:error, "Unknown task_id: #{task_id}"}
      end
    else
      {:error, "task_id is required for action=poll"}
    end
  end

  defp do_join(params, signal, opts) do
    ids =
      case Map.get(params, "task_ids") || Map.get(params, "task_id") do
        id when is_binary(id) -> [id]
        ids when is_list(ids) -> ids
        _ -> []
      end

    timeout_ms = Map.get(params, "timeout_ms", @default_sync_timeout_ms)

    if valid_timeout_ms?(timeout_ms) do
      with :ok <- authorize_task_ids(ids, opts) do
        with_parent_slot_lent(opts, signal, fn ->
          Result.do_join(params, signal, timeout_ms: timeout_ms)
        end)
      end
    else
      {:error, "timeout_ms must be a non-negative integer"}
    end
  end

  # A blocked parent lends its gateway permit so the children it waits on (and
  # their own delegations) can be admitted under the global cap. Abort paths
  # re-queue without waiting so cancellation is never held behind admission.
  defp with_parent_slot_lent(opts, signal, fun) do
    case lend_parent_slot(opts) do
      {:ok, server, token} ->
        try do
          fun.()
        after
          mode = if AbortSignal.aborted?(signal), do: :nowait, else: :wait
          resume_parent_slot(server, token, mode)
        end

      :none ->
        fun.()
    end
  end

  defp lend_parent_slot(opts) do
    server = Keyword.get(opts, :slots, LemonGateway.Slots)

    with run_id when is_binary(run_id) <- Keyword.get(opts, :run_id),
         pid when is_pid(pid) <- GenServer.whereis(server),
         {:ok, token} <- LemonGateway.Slots.suspend(run_id, pid) do
      {:ok, pid, token}
    else
      _ -> :none
    end
  catch
    :exit, _reason -> :none
  end

  defp resume_parent_slot(server, token, mode) do
    LemonGateway.Slots.resume(token, mode, server)
  catch
    :exit, _reason -> :ok
  end

  defp ensure_latest_task_state(task_id) do
    case TaskStore.get(task_id) do
      {:ok, record, _events} ->
        maybe_promote_from_run_store(task_id, record)

        case TaskStore.get(task_id) do
          {:ok, updated_record, updated_events} -> {:ok, updated_record, updated_events}
          {:error, :not_found} -> {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp maybe_promote_from_run_store(_task_id, %{status: status})
       when status not in [:queued, :running, :tracking_lost],
       do: :ok

  defp maybe_promote_from_run_store(task_id, record) do
    case Map.get(record, :run_id) do
      run_id when is_binary(run_id) ->
        case Store.get_run(run_id) do
          %{summary: summary} when is_map(summary) ->
            completion = completion_from_summary(summary)

            if completion do
              finalize_task_from_completion(task_id, completion, %{
                run_id: run_id,
                agent_id: Map.get(record, :agent_id),
                delegated_session_key: Map.get(record, :delegated_session_key),
                role: Map.get(record, :role)
              })
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp handle_async_submission(run_id, validated, delegated_session_key, request, opts) do
    {task_id, watcher_result} =
      track_submission(run_id, validated, delegated_session_key, request, opts)

    build_async_submission_result(
      watcher_result,
      task_id,
      run_id,
      validated,
      delegated_session_key
    )
  end

  # The router may have accepted the request before the reply was lost. Track the
  # fixed run id so a late completion still lands, and never resubmit.
  defp handle_unknown_submission(request, validated, delegated_session_key, opts) do
    run_id = request.run_id

    case track_submission(run_id, validated, delegated_session_key, request, opts) do
      {task_id, :ok} ->
        TaskStore.mark_tracking_lost(task_id, :submission_outcome_unknown)

        %AgentToolResult{
          content: [
            %TextContent{
              text:
                "Submission outcome for delegated run #{run_id} is unknown (task #{task_id}). " <>
                  "It may still run; poll or join the task. Do not resubmit."
            }
          ],
          details: %{
            status: "tracking_lost",
            task_id: task_id,
            run_id: run_id,
            agent_id: validated.agent_id,
            session_key: delegated_session_key,
            role: validated.role_id,
            node: result_node(validated),
            error: "outcome_unknown"
          }
        }

      {task_id, watcher_error} ->
        build_async_submission_result(
          watcher_error,
          task_id,
          run_id,
          validated,
          delegated_session_key
        )
    end
  end

  defp track_submission(run_id, validated, delegated_session_key, request, opts) do
    task_id =
      TaskStore.new_task(%{
        description: validated.description,
        kind: :agent,
        owner: Control.owner(opts),
        run_id: run_id,
        parent_run_id: Keyword.get(opts, :parent_run_id) || Keyword.get(opts, :run_id),
        session_key: Keyword.get(opts, :session_key),
        parent_session_id: Keyword.get(opts, :session_id) || Keyword.get(opts, :parent_session),
        parent_agent_id: Keyword.get(opts, :agent_id),
        agent_id: validated.agent_id,
        delegated_session_key: delegated_session_key,
        role: validated.role_id,
        node: result_node(validated)
      })

    :ok = register_child_run(run_id, validated, delegated_session_key, opts)
    :ok = RunGraph.update(run_id, &Map.put(&1, :task_id, task_id))

    watcher =
      start_completion_watcher(task_id, run_id, validated, delegated_session_key, request, opts)

    if watcher != :ok, do: release_child(delegation(opts, run_id).reservation, :untracked)
    {task_id, watcher}
  end

  defp build_async_submission_result(:ok, task_id, run_id, validated, delegated_session_key) do
    %AgentToolResult{
      content: [
        %TextContent{
          text:
            "Delegated run queued for agent #{validated.agent_id} (task #{task_id}, run #{run_id})."
        }
      ],
      details: %{
        status: "queued",
        task_id: task_id,
        run_id: run_id,
        agent_id: validated.agent_id,
        session_key: delegated_session_key,
        auto_followup: validated.auto_followup,
        role: validated.role_id,
        node: result_node(validated)
      }
    }
  end

  defp build_async_submission_result(
         {:error, reason},
         task_id,
         run_id,
         validated,
         delegated_session_key
       ) do
    tracking_error = {:completion_watcher_start_failed, reason}
    mark_delegated_run_failed(run_id, tracking_error)
    TaskStore.fail(task_id, tracking_error)

    Logger.warning(
      "Agent tool submitted run but failed to start completion watcher " <>
        "task_id=#{inspect(task_id)} run_id=#{inspect(run_id)} reason=#{inspect(reason)}"
    )

    %AgentToolResult{
      content: [
        %TextContent{
          text:
            "Delegated run #{run_id} was submitted, but local completion tracking failed " <>
              "(task #{task_id})."
        }
      ],
      details: %{
        status: "tracking_error",
        task_id: task_id,
        run_id: run_id,
        agent_id: validated.agent_id,
        session_key: delegated_session_key,
        auto_followup: false,
        role: validated.role_id,
        node: result_node(validated),
        error: inspect(reason)
      }
    }
  end

  # Registered before submission so the budget reservation and the child's
  # limits exist before the child can start; tracking adds its task id.
  defp register_child_run(run_id, validated, delegated_session_key, opts) do
    parent_run_id = parent_run_id(opts)

    case RunGraph.get(run_id) do
      {:ok, _record} ->
        :ok

      {:error, :not_found} ->
        now = System.system_time(:second)

        RunGraph.insert_record(run_id, %{
          id: run_id,
          status: :queued,
          inserted_at: now,
          updated_at: now,
          parent: parent_run_id,
          session_key: Keyword.get(opts, :session_key),
          parent_session_id: Keyword.get(opts, :session_id) || Keyword.get(opts, :parent_session),
          children: [],
          type: :agent,
          agent_id: validated.agent_id,
          delegated_session_key: delegated_session_key,
          description: validated.description,
          node: result_node(validated)
        })

        if is_binary(parent_run_id) and parent_run_id != "" and parent_run_id != run_id do
          RunGraph.add_child(parent_run_id, run_id)
        end

        :ok
    end
  end

  defp parent_run_id(opts), do: Keyword.get(opts, :parent_run_id) || Keyword.get(opts, :run_id)

  defp delegation(opts, run_id) do
    Map.merge(
      %{signal: nil, reservation: run_id, parent_scope: nil},
      Keyword.get(opts, :delegation, %{})
    )
  end

  # Refuse before submission when the parent's session budget is exhausted or
  # its run-graph budget (tokens, cost or child count) leaves no room.
  defp check_spawn_budget(opts) do
    parent_run_id = parent_run_id(opts)

    check =
      case LemonAgent.BudgetScope.check(Keyword.get(opts, :budget_scope)) do
        nil when is_binary(parent_run_id) -> BudgetEnforcer.check_subagent_spawn(parent_run_id)
        nil -> :ok
        details -> {:error, :budget_exceeded, details}
      end

    case check do
      {:error, _reason, details} -> {:error, budget_message(parent_run_id, details)}
      _ -> :ok
    end
  end

  # Reserve the child against its parent and send its limits with the request:
  # the child session enforces them itself and stops when it exceeds them.
  defp reserve_child(%RunRequest{run_id: run_id} = request, validated, session_key, opts) do
    :ok = register_child_run(run_id, validated, session_key, opts)
    BudgetEnforcer.on_run_start(run_id)

    reservation =
      case parent_run_id(opts) do
        parent when is_binary(parent) and parent != run_id ->
          BudgetEnforcer.on_subagent_spawn(parent, run_id)

        _ ->
          :ok
      end

    case reservation do
      :ok ->
        meta = Map.drop(request.meta || %{}, [:delegated_budget, "delegated_budget"])

        meta =
          case BudgetEnforcer.delegated_limits(run_id) do
            nil -> meta
            limits -> Map.put(meta, :delegated_budget, limits)
          end

        {:ok, %{request | meta: meta}}

      {:error, :budget_exceeded, details} ->
        mark_delegated_run_failed(run_id, {:budget_exceeded, details})
        {:error, budget_message(parent_run_id(opts), details)}

      {:error, reason} ->
        mark_delegated_run_failed(run_id, {:budget_reservation_failed, reason})
        {:error, "Unable to reserve delegated run budget: #{inspect(reason)}"}
    end
  end

  defp budget_message(run_id, details) do
    {_action, message} = BudgetEnforcer.handle_budget_exceeded(run_id || "unknown", details)
    message
  end

  # The child never ran (or is no longer tracked): free its parent slot.
  defp release_child(run_id, reason) do
    mark_delegated_run_failed(run_id, reason)
    BudgetEnforcer.on_run_complete(run_id, %{})
  end

  # Charge a finished child's reported usage to the parent's run-graph budget
  # and to the parent session's inclusive budget scope.
  defp settle_child(run_id, completion, opts) do
    %{reservation: reservation, parent_scope: scope} = delegation(opts, run_id)

    case completion[:usage] do
      usage when is_map(usage) ->
        BudgetEnforcer.on_run_complete(reservation, %{usage: usage})
        report_parent_usage(scope, reservation, usage)

      _ ->
        BudgetEnforcer.on_run_complete(reservation, %{})
    end
  end

  defp parent_budget_scope(opts) do
    case Keyword.get(opts, :budget_scope) do
      scope when is_pid(scope) -> LemonAgent.BudgetScope.attachment(scope)
      _ -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp report_parent_usage(nil, _run_id, _usage), do: :ok

  defp report_parent_usage(scope, run_id, usage) do
    LemonAgent.BudgetScope.report(
      scope,
      run_id,
      LemonAgent.Budget.usage_from_message(%{usage: usage})
    )
  catch
    # The delegating session may have ended before an async child finished.
    :exit, _reason -> :ok
  end

  # Cancel a child whose parent stopped waiting for it. The child's own run
  # emits its terminal event; the router owns the cancellation.
  defp stop_child(run_id, reason, opts) do
    router = run_orchestrator(opts)

    result =
      if Code.ensure_loaded?(router) and function_exported?(router, :abort_run, 2),
        do: router.abort_run(run_id, reason),
        else: {:error, :abort_unsupported}

    if result != :ok do
      Logger.warning(
        "Agent tool could not abort delegated run run_id=#{run_id} " <>
          "reason=#{inspect(reason)} result=#{LemonCore.StatusRedaction.inspect_reason(result)}"
      )
    end

    release_child(delegation(opts, run_id).reservation, reason)
    result
  rescue
    _error ->
      release_child(delegation(opts, run_id).reservation, reason)
      {:error, :abort_failed}
  catch
    :exit, _reason ->
      release_child(delegation(opts, run_id).reservation, reason)
      {:error, :outcome_unknown}
  end

  defp wait_sync_completion(run_id, validated, delegated_session_key, signal, opts) do
    mark_delegated_run_running(run_id)

    result =
      with_parent_slot_lent(opts, signal, fn ->
        await_run_completion(run_id, validated.timeout_ms, signal: signal)
      end)

    case result do
      {:ok, completion} ->
        settle_child(run_id, completion, opts)

        if completion.ok do
          result = %AgentToolResult{
            content: [%TextContent{text: completion.answer}],
            details: %{
              status: "completed",
              run_id: run_id,
              agent_id: validated.agent_id,
              session_key: delegated_session_key,
              duration_ms: completion.duration_ms,
              role: validated.role_id,
              node: result_node(validated)
            }
          }

          mark_delegated_run_finished(run_id, result)
          result
        else
          mark_delegated_run_failed(run_id, completion.error)
          {:error, "Delegated run failed: #{format_error(completion.error)}"}
        end

      {:error, :aborted} ->
        stop_child(run_id, :parent_aborted, opts)
        {:error, "Operation aborted; delegated run #{run_id} was cancelled"}

      {:error, :timeout} ->
        stop_child(run_id, :delegation_timeout, opts)
        {:error, "Timed out waiting for delegated run #{run_id}; it was cancelled"}

      {:error, reason} ->
        {:error, "Failed waiting for delegated run #{run_id}: #{inspect(reason)}"}
    end
  end

  defp build_run_request(validated, delegated_session_key, cwd, opts) do
    parent_session_key = Keyword.get(opts, :session_key)
    parent_session_id = Keyword.get(opts, :session_id) || Keyword.get(opts, :parent_session)
    parent_agent_id = Keyword.get(opts, :agent_id)
    parent_run_id = Keyword.get(opts, :parent_run_id) || Keyword.get(opts, :run_id)

    role_cwd = Keyword.get(opts, :config_cwd) || validated.cwd || cwd

    with {:ok, prompt, persona} <-
           maybe_apply_role_prompt(validated.prompt, validated.role_id, role_cwd) do
      child_policy =
        if persona,
          do: Subagents.tool_policy(persona, validated.tool_policy),
          else: validated.tool_policy

      run_id = LemonCore.Id.run_id()

      with {:ok, execution_context} <-
             delegated_execution_context(validated, child_policy, run_id, cwd, opts),
           {:ok, request_cwd} <- delegated_cwd(validated, execution_context, cwd),
           {:ok, model, model_origin} <- delegated_model(validated, persona, role_cwd, opts) do
        base_meta =
          %{
            parent_run_id: parent_run_id,
            delegated_by: %{
              run_id: parent_run_id,
              session_key: parent_session_key,
              session_id: parent_session_id,
              agent_id: parent_agent_id
            },
            delegated: %{
              target_agent_id: validated.agent_id,
              auto_followup: validated.auto_followup,
              role: validated.role_id
            }
          }
          |> compact_map()

        meta =
          validated.meta
          |> Map.drop([
            :delegated_by,
            "delegated_by",
            :delegated,
            "delegated",
            :parent_run_id,
            :invocation_context_key,
            "invocation_context_key",
            :invocationContextKey,
            "invocationContextKey",
            :memory_context_key,
            "memory_context_key",
            :memoryContextKey,
            "memoryContextKey",
            :memory_context_verified,
            "memory_context_verified",
            :memoryContextVerified,
            "memoryContextVerified",
            :shared_memory_grant,
            "shared_memory_grant",
            :sharedMemoryGrant,
            "sharedMemoryGrant",
            :mcp_servers,
            "mcp_servers",
            "parent_run_id"
          ])
          |> Map.merge(base_meta)
          |> Map.drop([
            :node,
            "node",
            :remote_cwd,
            "remote_cwd",
            :remote_cwd_explicit,
            "remote_cwd_explicit"
          ])
          |> put_execution_node(validated)
          |> Map.put(:invocation_context_key, Keyword.get(opts, :invocation_context_key))
          |> Map.put(:memory_context_key, Keyword.get(opts, :memory_context_key))
          |> Map.put(
            :memory_context_verified,
            Keyword.get(opts, :memory_context_verified) == true
          )
          |> Map.put(:shared_memory_grant, Keyword.get(opts, :shared_memory_grant) == true)
          |> Map.put(:mcp_servers, Keyword.get(opts, :invocation_mcp_servers))
          # Provenance of the concrete model admitted against this session's
          # settings; only a project origin travels (it can only tighten).
          |> Map.drop(["model_origin"])
          |> Map.put(:model_origin, if(model_origin == :project, do: :project))
          |> compact_map()

        request =
          RunRequest.new(%{
            run_id: run_id,
            origin: :node,
            session_key: delegated_session_key,
            agent_id: validated.agent_id,
            prompt: prompt,
            queue_mode: validated.queue_mode,
            model: model,
            model_explicit: not is_nil(validated.model) or Params.inherited_model_explicit(opts),
            cwd: request_cwd,
            tool_policy: execution_context.tool_policy,
            execution_context: execution_context,
            meta: meta
          })

        {:ok, request}
      end
    end
  end

  # A local child runs in the resolved directory checked against the parent's
  # canonical workspace (symlink escapes refused); a remote node keeps its own
  # separately bounded path.
  defp delegated_cwd(%{node: node} = validated, _context, cwd) when not is_nil(node),
    do: {:ok, validated.cwd || cwd}

  defp delegated_cwd(validated, context, cwd),
    do: LemonCore.ExecutionContext.canonical_cwd(context, validated.cwd || cwd)

  defp delegated_execution_context(validated, policy, run_id, cwd, opts) do
    alias LemonCore.ExecutionContext

    parent =
      case Keyword.get(opts, :execution_context) do
        nil ->
          ExecutionContext.new(
            run_id: Keyword.get(opts, :parent_run_id) || Keyword.get(opts, :run_id),
            cwd: cwd,
            agent_id: Keyword.get(opts, :agent_id),
            tool_policy: Keyword.get(opts, :tool_policy)
          )

        context ->
          ExecutionContext.validate(context)
      end

    with {:ok, parent} <- parent,
         {:ok, child} <-
           ExecutionContext.child(parent,
             run_id: run_id,
             cwd: if(validated.node, do: cwd, else: validated.cwd || cwd),
             tool_policy: policy,
             provenance: %{origin: "agent", delegated_by: ExecutionContext.identity(parent)}
           ) do
      if validated.node,
        do: ExecutionContext.for_remote(child, validated.cwd),
        else: {:ok, child}
    end
  end

  defp submit_run(request, opts) do
    router = run_orchestrator(opts)

    context = Map.new(opts)

    request = %{
      request
      | meta: Params.continuation_metadata(request.meta, context)
    }

    result =
      if Params.managed_context?(context) do
        Params.submit_native_followup(
          context,
          %{
            request
            | queue_mode: :collect,
              meta: LemonCore.RunStore.execution_projection(request.meta || %{})
          }
        )
      else
        submit_with_orchestrator(router, request)
      end

    case result do
      {:ok, run_id} when is_binary(run_id) -> {:ok, run_id}
      {:ok, other} -> {:error, "Unexpected run id: #{inspect(other)}"}
      {:error, {:unknown_agent_id, agent_id}} -> {:error, "Unknown agent_id: #{agent_id}"}
      {:error, :outcome_unknown} -> {:error, :outcome_unknown}
      {:error, reason} -> {:error, "Delegated run submission failed: #{inspect(reason)}"}
    end
  end

  defp submit_with_orchestrator(router, request) do
    cond do
      function_exported?(router, :submit_run, 1) ->
        router.submit_run(request)

      function_exported?(router, :submit, 1) ->
        router.submit(request)

      true ->
        {:error, :unavailable}
    end
  end

  defp start_completion_watcher(task_id, run_id, validated, delegated_session_key, request, opts) do
    watcher_timeout_ms =
      Keyword.get(opts, :agent_tool_watcher_timeout_ms, @default_watcher_timeout_ms)

    ready_ref = make_ref()

    watcher_opts = %{
      task_id: task_id,
      run_id: run_id,
      timeout_ms: watcher_timeout_ms,
      validated: validated,
      delegated_session_key: delegated_session_key,
      request: request,
      subscribe_notify: {self(), ready_ref},
      opts: opts
    }

    task_supervisor = Keyword.get(opts, :task_supervisor, CodingAgent.TaskSupervisor)

    case LemonCore.TaskSupervisor.start_child(task_supervisor, fn ->
           monitor_completion(watcher_opts)
         end) do
      {:ok, _pid} ->
        receive do
          {:agent_tool_watcher_ready, ^ready_ref} -> :ok
        after
          150 -> :ok
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp monitor_completion(%{
         task_id: task_id,
         run_id: run_id,
         timeout_ms: timeout_ms,
         validated: validated,
         delegated_session_key: delegated_session_key,
         request: request,
         subscribe_notify: subscribe_notify,
         opts: opts
       }) do
    TaskStore.mark_running(task_id)
    mark_delegated_run_running(run_id)

    on_subscribed =
      if match?({pid, _} when is_pid(pid), subscribe_notify) do
        {notify_pid, notify_ref} = subscribe_notify
        fn -> send(notify_pid, {:agent_tool_watcher_ready, notify_ref}) end
      else
        nil
      end

    signal = delegation(opts, run_id).signal

    case await_run_completion(run_id, timeout_ms, on_subscribed: on_subscribed, signal: signal) do
      {:ok, completion} ->
        finalize_task_from_completion(task_id, completion, %{
          run_id: run_id,
          agent_id: validated.agent_id,
          delegated_session_key: delegated_session_key,
          role: validated.role_id,
          node: result_node(validated)
        })

        settle_child(run_id, completion, opts)

        if validated.auto_followup do
          maybe_send_auto_followup(completion, run_id, task_id, validated, request, opts)
        end

      {:error, :aborted} ->
        # The run that delegated was aborted: cancel the child and record the
        # terminal event it emits. No followup goes to the aborted parent.
        stop_child(run_id, :parent_aborted, opts)
        grace_ms = Keyword.get(opts, :agent_tool_abort_grace_ms, @default_abort_grace_ms)

        case await_run_completion(run_id, grace_ms) do
          {:ok, completion} ->
            finalize_task_from_completion(task_id, completion, %{
              run_id: run_id,
              agent_id: validated.agent_id,
              delegated_session_key: delegated_session_key,
              role: validated.role_id,
              node: result_node(validated)
            })

          _ ->
            TaskStore.fail(task_id, :parent_aborted)
        end

      {:error, :timeout} ->
        TaskStore.mark_tracking_lost(task_id, :watcher_timeout)

        reconcile_late_completion(
          task_id,
          run_id,
          validated,
          delegated_session_key,
          request,
          opts
        )

      {:error, reason} ->
        release_child(delegation(opts, run_id).reservation, reason)
        TaskStore.fail(task_id, reason)
    end
  rescue
    error ->
      Logger.warning("Agent tool watcher crashed for task_id=#{task_id}: #{inspect(error)}")
      release_child(delegation(opts, run_id).reservation, {:watcher_crash, error})
      TaskStore.fail(task_id, {:watcher_crash, error})
  catch
    kind, reason ->
      Logger.warning(
        "Agent tool watcher exited for task_id=#{task_id}: #{inspect({kind, reason})}"
      )

      release_child(delegation(opts, run_id).reservation, {:watcher_crash, {kind, reason}})
      TaskStore.fail(task_id, {:watcher_crash, {kind, reason}})
  end

  defp reconcile_late_completion(
         task_id,
         run_id,
         validated,
         delegated_session_key,
         request,
         opts
       ) do
    timeout_ms =
      Keyword.get(
        opts,
        :agent_tool_reconciliation_timeout_ms,
        @default_reconciliation_timeout_ms
      )

    case await_run_completion(run_id, timeout_ms) do
      {:ok, completion} ->
        finalize_task_from_completion(task_id, completion, %{
          run_id: run_id,
          agent_id: validated.agent_id,
          delegated_session_key: delegated_session_key,
          role: validated.role_id
        })

        settle_child(run_id, completion, opts)

        if validated.auto_followup do
          maybe_send_auto_followup(completion, run_id, task_id, validated, request, opts)
        end

      {:error, :timeout} ->
        Logger.warning(
          "Agent tool reconciliation still has no terminal result for task_id=#{task_id} run_id=#{run_id}"
        )

      {:error, reason} ->
        Logger.warning(
          "Agent tool reconciliation failed for task_id=#{task_id}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_send_auto_followup(completion, run_id, task_id, validated, request, opts) do
    context =
      opts
      |> Map.new()
      |> Map.put(:parent_session_key, Keyword.get(opts, :session_key))
      |> Map.put(:parent_agent_id, Keyword.get(opts, :agent_id))
      |> Map.put(
        :queue_mode,
        AsyncFollowups.resolve_async_followup_queue_mode(validated.followup_queue_mode, :followup)
      )
      |> Map.put(:run_orchestrator, run_orchestrator(opts))
      |> Map.put(:meta, %{})

    AsyncFollowups.enqueue(
      context,
      auto_followup_text(completion, run_id, validated),
      %{
        source: :agent,
        task_id: task_id,
        run_id: run_id,
        agent_id: validated.agent_id,
        session_key: request.session_key
      },
      Keyword.get(opts, :async_followup_server, AsyncFollowups)
    )
  rescue
    error ->
      Logger.warning(
        "Failed to auto-followup delegated run #{run_id} (task #{task_id}): #{inspect(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Failed to auto-followup delegated run #{run_id} (task #{task_id}): " <>
          inspect({kind, reason})
      )

      :ok
  end

  defp run_orchestrator(opts) do
    Keyword.get(opts, :run_orchestrator, @default_run_orchestrator)
  end

  # `signal` (the delegating run's abort signal) ends the wait with
  # `{:error, :aborted}`; the caller cancels the child.
  defp await_run_completion(run_id, timeout_ms, opts \\ []) do
    # Subscribe before reading the durable summary so a completion between the
    # store check and entering the receive loop is still observable.
    topic = Bus.run_topic(run_id)
    :ok = Bus.subscribe(topic)
    signal = Keyword.get(opts, :signal)
    AbortSignal.subscribe(signal)
    on_subscribed = Keyword.get(opts, :on_subscribed)

    if is_function(on_subscribed, 0) do
      on_subscribed.()
    end

    try do
      # Now check the store — if already complete, return immediately
      case completion_from_store(run_id, "") do
        {:ok, completion} ->
          {:ok, completion}

        :pending ->
          if AbortSignal.aborted?(signal) do
            {:error, :aborted}
          else
            deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
            await_completion_loop(run_id, deadline_ms, "", signal)
          end
      end
    after
      AbortSignal.unsubscribe(signal)
      _ = Bus.unsubscribe(topic)
    end
  end

  defp await_completion_loop(run_id, deadline_ms, acc_answer, signal) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      case completion_from_store(run_id, acc_answer) do
        {:ok, completion} -> {:ok, completion}
        :pending -> {:error, :timeout}
      end
    else
      receive do
        %LemonCore.Event{type: :delta, payload: payload} ->
          delta = delta_text(payload)
          await_completion_loop(run_id, deadline_ms, acc_answer <> delta, signal)

        %LemonCore.Event{type: :run_completed, payload: payload} ->
          {:ok, normalize_completion(Events.coerce(:run_completed, payload), acc_answer)}

        {:lemon_abort, ^signal, :abort} ->
          {:error, :aborted}

        _ ->
          await_completion_loop(run_id, deadline_ms, acc_answer, signal)
      after
        remaining_ms ->
          case completion_from_store(run_id, acc_answer) do
            {:ok, completion} ->
              {:ok, completion}

            :pending ->
              {:error, :timeout}
          end
      end
    end
  end

  defp completion_from_store(run_id, acc_answer) when is_binary(run_id) do
    case Store.get_run(run_id) do
      %{summary: summary} when is_map(summary) ->
        case completion_from_summary(summary) do
          %{ok: _ok} = completion -> {:ok, merge_completion_answer(completion, acc_answer)}
          _ -> :pending
        end

      _ ->
        :pending
    end
  rescue
    _ -> :pending
  end

  defp completion_from_store(_run_id, _acc_answer), do: :pending

  defp merge_completion_answer(%{answer: answer} = completion, _acc_answer)
       when is_binary(answer) and answer != "" do
    completion
  end

  defp merge_completion_answer(completion, acc_answer) when is_binary(acc_answer) do
    Map.put(completion, :answer, acc_answer)
  end

  defp merge_completion_answer(completion, _acc_answer), do: completion

  defp normalize_completion(
         %Events.RunCompleted{completed: completed, duration_ms: duration_ms},
         acc_answer
       ) do
    build_completion(completed, duration_ms, acc_answer)
  end

  defp normalize_completion(payload, acc_answer) when is_map(payload) do
    build_completion(
      map_get(payload, :completed) || payload,
      map_get(payload, :duration_ms),
      acc_answer
    )
  end

  defp normalize_completion(_payload, acc_answer) do
    %{ok: true, answer: acc_answer || "", error: nil, duration_ms: nil}
  end

  # `completed` is a `LemonCore.Events.Completion` off the bus and a plain map when it comes
  # from the run store; `map_get/2` reads both without needing `Access` on the struct.
  defp build_completion(completed, duration_ms, acc_answer) do
    ok = map_get_default(completed, :ok, true)
    answer = map_get_default(completed, :answer, acc_answer || "")

    %{
      ok: ok != false,
      answer: normalize_answer(answer, acc_answer),
      error: map_get(completed, :error),
      usage: map_get(completed, :usage),
      duration_ms: duration_ms
    }
  end

  defp completion_from_summary(summary) when is_map(summary) do
    completed = summary[:completed] || summary["completed"]

    if is_map(completed) do
      normalize_completion(%{completed: completed}, "")
    else
      nil
    end
  end

  defp normalize_answer(answer, _fallback) when is_binary(answer), do: answer
  defp normalize_answer(nil, fallback) when is_binary(fallback), do: fallback
  defp normalize_answer(nil, _fallback), do: ""
  defp normalize_answer(answer, _fallback), do: inspect(answer)

  defp delta_text(%{text: text}) when is_binary(text), do: text
  defp delta_text(%{"text" => text}) when is_binary(text), do: text
  defp delta_text(_), do: ""

  defp finalize_task_from_completion(task_id, completion, details) do
    if completion.ok do
      result = %AgentToolResult{
        content: [%TextContent{text: completion.answer}],
        details:
          details
          |> Map.put(:status, "completed")
          |> Map.put(:ok, true)
          |> Map.put(:duration_ms, completion.duration_ms)
      }

      mark_delegated_run_finished(Map.get(details, :run_id), result)
      TaskStore.finish(task_id, result)
    else
      error = %{
        status: "error",
        error: completion.error,
        answer: completion.answer,
        details: details
      }

      mark_delegated_run_failed(Map.get(details, :run_id), error)
      TaskStore.fail(task_id, error)
    end
  end

  defp mark_delegated_run_running(run_id) when is_binary(run_id) do
    case RunGraph.mark_running(run_id) do
      :ok -> :ok
      {:error, :invalid_transition} -> :ok
    end
  end

  defp mark_delegated_run_running(_run_id), do: :ok

  defp mark_delegated_run_finished(run_id, result) when is_binary(run_id) do
    case RunGraph.finish(run_id, result) do
      :ok -> :ok
      {:error, :invalid_transition} -> :ok
    end
  end

  defp mark_delegated_run_finished(_run_id, _result), do: :ok

  defp mark_delegated_run_failed(run_id, error) when is_binary(run_id) do
    case RunGraph.fail(run_id, error) do
      :ok -> :ok
      {:error, :invalid_transition} -> :ok
    end
  end

  defp mark_delegated_run_failed(_run_id, _error), do: :ok

  defp auto_followup_text(completion, run_id, validated) do
    agent_id = validated.agent_id
    description = normalize_optional_string(validated[:description])
    model = normalize_optional_string(validated[:model])
    role = normalize_optional_string(validated[:role_id])

    summary =
      if is_binary(description) and description != "", do: description, else: "delegated task"

    base = "[agent #{agent_id}] #{summary}"

    labels =
      [
        if(is_binary(model) and model != "", do: model, else: nil),
        if(is_binary(role) and role != "", do: "role: #{role}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    paren_content =
      case labels do
        [] -> ""
        _ -> " (#{Enum.join(labels, " | ")})"
      end

    base = base <> paren_content <> " run=#{short_id(run_id)}"

    duration_str =
      if is_integer(completion.duration_ms) and completion.duration_ms > 0 do
        " #{format_duration(completion.duration_ms)}"
      else
        ""
      end

    cond do
      completion.ok and String.trim(completion.answer || "") == "" ->
        "#{base} completed.#{duration_str}"

      completion.ok ->
        "#{base} completed.#{duration_str}\n\n#{completion.answer}"

      String.trim(completion.answer || "") == "" ->
        "#{base} failed: #{format_error(completion.error)}#{duration_str}"

      true ->
        "#{base} failed: #{format_error(completion.error)}#{duration_str}\n\nPartial output:\n#{completion.answer}"
    end
  end

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_), do: "?"

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp validate_run_params(params, cwd, opts) when is_map(params) do
    agent_id = Map.get(params, "agent_id") |> normalize_optional_string()
    prompt = Map.get(params, "prompt")
    description = Map.get(params, "description") |> normalize_optional_string()
    role_id = Map.get(params, "role") |> normalize_optional_string()
    async? = Map.get(params, "async", true)
    auto_followup = Map.get(params, "auto_followup", true)
    continue_session = Map.get(params, "continue_session", true)
    queue_mode = Map.get(params, "queue_mode", "collect")
    followup_queue_mode = Map.get(params, "followup_queue_mode")
    timeout_ms = Map.get(params, "timeout_ms", @default_sync_timeout_ms)
    tool_policy = Map.get(params, "tool_policy")
    meta = Map.get(params, "meta")
    raw_delegated_cwd = Map.get(params, "cwd")
    delegated_cwd = normalize_optional_string(raw_delegated_cwd)
    raw_node = Map.get(params, "node")
    node = normalize_optional_string(raw_node)
    model = Map.get(params, "model")
    role_cwd = Keyword.get(opts, :config_cwd) || delegated_cwd || cwd

    cond do
      not is_binary(agent_id) ->
        {:error, "agent_id is required and must be a non-empty string"}

      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "prompt is required and must be a non-empty string"}

      not is_nil(role_id) and Subagents.get(role_cwd, role_id) == nil ->
        {:error, "Unknown role: #{role_id}"}

      not is_boolean(async?) ->
        {:error, "async must be a boolean"}

      not is_boolean(auto_followup) ->
        {:error, "auto_followup must be a boolean"}

      not is_boolean(continue_session) ->
        {:error, "continue_session must be a boolean"}

      # Delegated sessions are derived from the launching session, never chosen
      # by the model: an explicit key could steer another conversation.
      Map.has_key?(params, "session_key") ->
        {:error, "session_key is not accepted; delegated sessions derive from this session"}

      not valid_queue_mode?(queue_mode) ->
        {:error, "queue_mode must be one of: #{Enum.join(@valid_queue_modes, ", ")}"}

      not is_nil(followup_queue_mode) and not valid_queue_mode?(followup_queue_mode) ->
        {:error, "followup_queue_mode must be one of: #{Enum.join(@valid_queue_modes, ", ")}"}

      not valid_timeout_ms?(timeout_ms) ->
        {:error, "timeout_ms must be a non-negative integer"}

      not is_nil(tool_policy) and not is_map(tool_policy) ->
        {:error, "tool_policy must be an object"}

      not is_nil(tool_policy) and
          match?({:error, _}, LemonCore.ToolPolicy.parse(tool_policy)) ->
        {:error, "Invalid tool_policy"}

      not is_nil(meta) and not is_map(meta) ->
        {:error, "meta must be an object"}

      not is_nil(raw_delegated_cwd) and not is_binary(raw_delegated_cwd) ->
        {:error, "cwd must be a string"}

      not is_nil(raw_node) and not is_binary(raw_node) ->
        {:error, "node must be a string"}

      not is_nil(model) and not is_binary(model) ->
        {:error, "model must be a string"}

      true ->
        {:ok,
         %{
           agent_id: agent_id,
           prompt: prompt,
           description: description || "Delegated run for #{agent_id}",
           role_id: role_id,
           async: async?,
           auto_followup: auto_followup,
           continue_session: continue_session,
           queue_mode: normalize_queue_mode(queue_mode),
           followup_queue_mode:
             if(is_nil(followup_queue_mode),
               do: nil,
               else: normalize_queue_mode(followup_queue_mode)
             ),
           timeout_ms: timeout_ms,
           tool_policy: tool_policy,
           meta: meta || %{},
           cwd: delegated_cwd,
           node: node,
           model: normalize_optional_string(model)
         }}
    end
  end

  defp validate_run_params(_, _cwd, _opts), do: {:error, "params must be an object"}

  defp maybe_apply_role_prompt(prompt, nil, _cwd), do: {:ok, prompt, nil}
  defp maybe_apply_role_prompt(prompt, "", _cwd), do: {:ok, prompt, nil}

  defp maybe_apply_role_prompt(prompt, role_id, cwd) do
    with {:ok, persona} <- Subagents.fetch(cwd, role_id) do
      {:ok, persona.prompt <> "\n\n" <> prompt, persona}
    end
  end

  # The delegated run's model, resolved against this (parent) session's
  # settings snapshot into a concrete `provider:id`, never an alias the
  # destination could re-resolve under its own cwd's project config. An
  # explicit selector is the caller's (already through the per-call
  # preflight); a persona's model passes the gate when the persona (or the
  # role it names) comes from the project, and a refused one leaves the run
  # on its operator profile and defaults.
  defp delegated_model(%{model: model}, _persona, cwd, opts) when is_binary(model),
    do: ModelProvenance.delegate(model, parent_settings(cwd, opts))

  defp delegated_model(_validated, persona, cwd, opts) do
    selector =
      case persona do
        %{model: model} when is_binary(model) -> model
        %{role: role} when is_binary(role) -> "@" <> role
        _ -> nil
      end

    origin = if match?(%{source: :project}, persona), do: :project, else: :operator

    case selector && ModelProvenance.admit(selector, origin, parent_settings(cwd, opts)) do
      {model, origin} -> {:ok, model, origin}
      nil -> {:ok, nil, nil}
    end
  end

  defp parent_settings(cwd, opts),
    do: Keyword.get(opts, :settings_manager) || SettingsManager.load(cwd)

  defp resolve_delegated_session_key(%{agent_id: agent_id, continue_session: true}, opts) do
    parent = parent_scope(opts)

    peer_id =
      parent
      |> short_hash()
      |> then(&"p#{&1}")

    {:ok,
     SessionKey.channel_peer(%{
       agent_id: agent_id,
       channel_id: "delegate",
       account_id: "agent",
       peer_kind: "main",
       peer_id: peer_id,
       thread_id: "oracle"
     })}
  end

  defp resolve_delegated_session_key(%{agent_id: agent_id}, _opts) do
    suffix = unique_suffix()

    {:ok,
     SessionKey.channel_peer(%{
       agent_id: agent_id,
       channel_id: "delegate",
       account_id: "agent",
       peer_kind: "main",
       peer_id: "r#{suffix}",
       thread_id: "oracle"
     })}
  end

  defp parent_scope(opts) do
    Keyword.get(opts, :session_key) ||
      Keyword.get(opts, :session_id) ||
      "unknown"
  end

  defp normalize_action(nil), do: "run"

  defp normalize_action(action) when is_binary(action) do
    action
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_action(_), do: "run"

  defp valid_queue_mode?(queue_mode) when is_atom(queue_mode) do
    valid_queue_mode?(Atom.to_string(queue_mode))
  end

  defp valid_queue_mode?(queue_mode) when is_binary(queue_mode) do
    queue_mode in @valid_queue_modes
  end

  defp valid_queue_mode?(_), do: false

  defp normalize_queue_mode(queue_mode) when is_atom(queue_mode), do: queue_mode

  defp normalize_queue_mode(queue_mode) when is_binary(queue_mode) do
    case queue_mode |> String.trim() |> String.downcase() do
      "collect" -> :collect
      "followup" -> :followup
      "steer" -> :steer
      "steer_backlog" -> :steer_backlog
      _ -> :collect
    end
  end

  defp normalize_queue_mode(_), do: :collect

  defp valid_timeout_ms?(value), do: is_integer(value) and value >= 0

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp short_hash(value) do
    :sha256
    |> :crypto.hash(to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp unique_suffix do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp put_execution_node(meta, %{node: nil}), do: meta

  defp put_execution_node(meta, %{node: "local"}) do
    Map.put(meta, :node, "local")
  end

  defp put_execution_node(meta, %{node: node, cwd: cwd}) do
    meta
    |> Map.put(:node, node)
    |> Map.put(:remote_cwd_explicit, is_binary(cwd))
    |> maybe_put_remote_cwd(cwd)
  end

  defp maybe_put_remote_cwd(meta, cwd) when is_binary(cwd), do: Map.put(meta, :remote_cwd, cwd)
  defp maybe_put_remote_cwd(meta, _cwd), do: meta

  defp result_node(%{node: node}) when is_binary(node), do: node
  defp result_node(_), do: "local"

  defp format_error(nil), do: "unknown"
  defp format_error(error) when is_binary(error), do: error

  defp format_error(error) do
    Logger.warning("Delegated agent failed: #{inspect(error)}")
    "The delegated agent failed unexpectedly. Run `lemon doctor` before trying again."
  end

  defp build_description do
    """
    Delegate via Lemon's router for agent-profile/node workflows and session continuity.
    Use task for native coding subagents. Prefer async=true: receipts are not answers;
    join task_ids for required same-turn results. auto_followup delivers later.
    Delegated sessions preserve continuity by default. Named execution nodes use their
    own credentials and working directory; cwd overrides the latter explicitly.
    """
    |> String.trim()
  end

  defp build_agent_id_property(cwd, opts) do
    ids = resolve_available_agent_ids(cwd, opts)

    base = %{
      "type" => "string",
      "description" => "Target agent profile; normally the current agent_id"
    }

    if ids == [] do
      base
    else
      Map.put(base, "enum", ids)
    end
  end

  defp build_role_property(cwd) do
    ids = Subagents.list(cwd) |> Enum.map(& &1.id)

    base = %{
      "type" => "string",
      "description" => "Optional discovered persona preset"
    }

    if ids == [] do
      base
    else
      Map.put(base, "enum", ids)
    end
  end

  defp resolve_available_agent_ids(cwd, opts) do
    case Keyword.get(opts, :available_agent_ids) do
      ids when is_list(ids) ->
        normalize_agent_ids(ids)

      _ ->
        load_config_agent_ids(cwd, opts)
    end
  end

  defp load_config_agent_ids(cwd, opts) do
    config =
      case Keyword.get(opts, :config) do
        cfg when is_map(cfg) -> cfg
        _ -> LemonCore.Config.cached(cwd)
      end

    ids =
      case map_get(config, :agents) do
        agents when is_map(agents) -> Map.keys(agents)
        _ -> []
      end

    normalize_agent_ids(ids)
  rescue
    _ -> ["default"]
  catch
    :exit, _ -> ["default"]
  end

  defp normalize_agent_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&normalize_agent_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> ensure_default_agent_id()
    |> Enum.sort()
  end

  defp normalize_agent_id(id) when is_binary(id) do
    id = String.trim(id)
    if id == "", do: nil, else: id
  end

  defp normalize_agent_id(id) when is_atom(id), do: normalize_agent_id(Atom.to_string(id))
  defp normalize_agent_id(_), do: nil

  defp ensure_default_agent_id(ids) do
    if "default" in ids do
      ids
    else
      ["default" | ids]
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp map_get_default(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get_default(_, _, default), do: default
end
