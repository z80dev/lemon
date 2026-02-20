defmodule CodingAgent.Tools.Agent do
  @moduledoc """
  Agent delegation tool.

  This tool submits work to another Lemon agent and can either:
  - return immediately with a `task_id` (`async=true`, default), or
  - wait for completion and return the delegated answer (`async=false`).

  Async runs can use `action=poll` to check status, and can optionally
  auto-follow up into the current session when the delegated run completes.
  """

  require Logger

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.TaskStore
  alias LemonCore.{Bus, RouterBridge, RunRequest, SessionKey, Store}

  @valid_actions ["run", "poll"]
  @valid_queue_modes ["collect", "followup", "steer", "steer_backlog", "interrupt"]
  @default_sync_timeout_ms 120_000
  @default_watcher_timeout_ms 30 * 60 * 1000
  @default_run_orchestrator RouterBridge

  @doc """
  Returns the agent delegation tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    agent_id_property = build_agent_id_property(cwd, opts)

    %AgentTool{
      name: "agent",
      description: build_description(),
      label: "Delegate To Agent",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" => "Action to perform: run (default) or poll"
          },
          "agent_id" => agent_id_property,
          "prompt" => %{
            "type" => "string",
            "description" => "Prompt to send to the delegated agent"
          },
          "description" => %{
            "type" => "string",
            "description" => "Optional short description for tracking"
          },
          "async" => %{
            "type" => "boolean",
            "description" => "When true (default), run in background and return task_id immediately. ALWAYS use async=true unless you absolutely must wait for the result before continuing."
          },
          "auto_followup" => %{
            "type" => "boolean",
            "description" =>
              "When true (default), forward delegated completion back into this session"
          },
          "continue_session" => %{
            "type" => "boolean",
            "description" =>
              "When true (default), reuse a deterministic delegated session for continuity"
          },
          "session_key" => %{
            "type" => "string",
            "description" =>
              "Optional explicit delegated session key (must be a valid Lemon session key)"
          },
          "queue_mode" => %{
            "type" => "string",
            "enum" => @valid_queue_modes,
            "description" => "Queue mode for delegated run (default: collect)"
          },
          "engine_id" => %{
            "type" => "string",
            "description" => "Optional engine override for delegated run"
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional model override for delegated run"
          },
          "tool_policy" => %{
            "type" => "object",
            "description" => "Optional delegated tool policy override map"
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Optional delegated working directory (defaults to current cwd)"
          },
          "meta" => %{
            "type" => "object",
            "description" => "Optional metadata map merged into delegated request"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Timeout for synchronous waiting (action=run and async=false, default: 120000)"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Task id to poll (action=poll)"
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
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
        "poll" -> do_poll(params)
        "run" -> do_run(params, cwd, opts)
        other -> {:error, "Unsupported action: #{inspect(other)}"}
      end
    end
  end

  defp do_run(params, cwd, opts) do
    with {:ok, validated} <- validate_run_params(params),
         {:ok, delegated_session_key} <- resolve_delegated_session_key(validated, opts),
         {:ok, request} <- build_run_request(validated, delegated_session_key, cwd, opts),
         {:ok, run_id} <- submit_run(request, opts) do
      if validated.async do
        handle_async_submission(run_id, validated, delegated_session_key, request, opts)
      else
        wait_sync_completion(run_id, validated, delegated_session_key)
      end
    end
  end

  defp do_poll(params) do
    task_id = Map.get(params, "task_id") |> normalize_optional_string()

    if is_binary(task_id) do
      with {:ok, record, events} <- ensure_latest_task_state(task_id) do
        build_poll_result(task_id, record, events)
      else
        {:error, :not_found} -> {:error, "Unknown task_id: #{task_id}"}
      end
    else
      {:error, "task_id is required for action=poll"}
    end
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
       when status not in [:queued, :running],
       do: :ok

  defp maybe_promote_from_run_store(task_id, record) do
    case Map.get(record, :run_id) do
      run_id when is_binary(run_id) ->
        case Store.get_run(run_id) do
          %{summary: summary} when is_map(summary) ->
            completion = completion_from_summary(summary)

            if completion do
              finalize_task_from_completion(task_id, completion, %{
                agent_id: Map.get(record, :agent_id),
                delegated_session_key: Map.get(record, :delegated_session_key)
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
    task_id =
      TaskStore.new_task(%{
        description: validated.description,
        kind: :agent,
        run_id: run_id,
        agent_id: validated.agent_id,
        delegated_session_key: delegated_session_key
      })

    start_completion_watcher(task_id, run_id, validated, delegated_session_key, request, opts)

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
        auto_followup: validated.auto_followup
      }
    }
  end

  defp wait_sync_completion(run_id, validated, delegated_session_key) do
    timeout_ms = validated.timeout_ms

    case await_run_completion(run_id, timeout_ms) do
      {:ok, completion} ->
        if completion.ok do
          %AgentToolResult{
            content: [%TextContent{text: completion.answer}],
            details: %{
              status: "completed",
              run_id: run_id,
              agent_id: validated.agent_id,
              session_key: delegated_session_key,
              duration_ms: completion.duration_ms
            }
          }
        else
          {:error, "Delegated run failed: #{format_error(completion.error)}"}
        end

      {:error, :timeout} ->
        {:error, "Timed out waiting for delegated run #{run_id}"}

      {:error, reason} ->
        {:error, "Failed waiting for delegated run #{run_id}: #{inspect(reason)}"}
    end
  end

  defp build_run_request(validated, delegated_session_key, cwd, opts) do
    parent_session_key = Keyword.get(opts, :session_key)
    parent_session_id = Keyword.get(opts, :session_id)
    parent_agent_id = Keyword.get(opts, :agent_id)

    base_meta =
      %{
        delegated_by: %{
          session_key: parent_session_key,
          session_id: parent_session_id,
          agent_id: parent_agent_id
        },
        delegated: %{
          target_agent_id: validated.agent_id,
          auto_followup: validated.auto_followup
        }
      }
      |> compact_map()

    meta =
      base_meta
      |> Map.merge(validated.meta)
      |> compact_map()

    request =
      RunRequest.new(%{
        origin: :node,
        session_key: delegated_session_key,
        agent_id: validated.agent_id,
        prompt: validated.prompt,
        queue_mode: validated.queue_mode,
        engine_id: validated.engine_id,
        model: validated.model,
        cwd: validated.cwd || cwd,
        tool_policy: validated.tool_policy,
        meta: meta
      })

    {:ok, request}
  end

  defp submit_run(request, opts) do
    router = run_orchestrator(opts)

    case submit_with_orchestrator(router, request) do
      {:ok, run_id} when is_binary(run_id) -> {:ok, run_id}
      {:ok, other} -> {:error, "Unexpected run id: #{inspect(other)}"}
      {:error, {:unknown_agent_id, agent_id}} -> {:error, "Unknown agent_id: #{agent_id}"}
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

    Task.start(fn -> monitor_completion(watcher_opts) end)

    receive do
      {:agent_tool_watcher_ready, ^ready_ref} -> :ok
    after
      150 -> :ok
    end

    :ok
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

    on_subscribed =
      if match?({pid, _} when is_pid(pid), subscribe_notify) do
        {notify_pid, notify_ref} = subscribe_notify
        fn -> send(notify_pid, {:agent_tool_watcher_ready, notify_ref}) end
      else
        nil
      end

    case await_run_completion(run_id, timeout_ms, on_subscribed: on_subscribed) do
      {:ok, completion} ->
        finalize_task_from_completion(task_id, completion, %{
          run_id: run_id,
          agent_id: validated.agent_id,
          delegated_session_key: delegated_session_key
        })

        if validated.auto_followup do
          maybe_send_auto_followup(completion, run_id, task_id, validated.agent_id, request, opts)
        end

      {:error, :timeout} ->
        TaskStore.fail(task_id, :timeout)

      {:error, reason} ->
        TaskStore.fail(task_id, reason)
    end
  rescue
    error ->
      Logger.warning("Agent tool watcher crashed for task_id=#{task_id}: #{inspect(error)}")
      TaskStore.fail(task_id, {:watcher_crash, error})
  end

  defp maybe_send_auto_followup(completion, run_id, task_id, target_agent_id, request, opts) do
    text = auto_followup_text(completion, run_id, target_agent_id)
    session_module = Keyword.get(opts, :session_module, CodingAgent.Session)
    session_pid = Keyword.get(opts, :session_pid)

    sent_to_live_session? =
      if is_pid(session_pid) and Process.alive?(session_pid) and
           function_exported?(session_module, :follow_up, 2) do
        _ = session_module.follow_up(session_pid, text)
        true
      else
        false
      end

    if not sent_to_live_session? do
      send_followup_via_router(text, run_id, task_id, target_agent_id, request, opts)
    end
  rescue
    error ->
      Logger.warning(
        "Failed to auto-followup delegated run #{run_id} (task #{task_id}): #{inspect(error)}"
      )

      :ok
  end

  defp send_followup_via_router(text, run_id, task_id, target_agent_id, request, opts) do
    parent_session_key = Keyword.get(opts, :session_key)

    parent_agent_id =
      Keyword.get(opts, :agent_id) || SessionKey.agent_id(parent_session_key || "")

    router = run_orchestrator(opts)
    delegated_session_key = request.session_key

    if is_binary(parent_session_key) and parent_session_key != "" do
      followup =
        RunRequest.new(%{
          origin: :node,
          session_key: parent_session_key,
          agent_id: parent_agent_id || "default",
          prompt: text,
          queue_mode: :followup,
          meta: %{
            delegated_auto_followup: true,
            delegated_run_id: run_id,
            delegated_task_id: task_id,
            delegated_agent_id: target_agent_id,
            delegated_session_key: delegated_session_key
          }
        })

      case router.submit(followup) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Agent tool followup submit failed: #{inspect(reason)}")
      end
    else
      Logger.warning(
        "Agent tool cannot auto-followup delegated run #{run_id}: parent session key unavailable"
      )
    end
  end

  defp run_orchestrator(opts) do
    Keyword.get(opts, :run_orchestrator, @default_run_orchestrator)
  end

  defp await_run_completion(run_id, timeout_ms, opts \\ []) do
    topic = Bus.run_topic(run_id)
    :ok = Bus.subscribe(topic)
    on_subscribed = Keyword.get(opts, :on_subscribed)

    if is_function(on_subscribed, 0) do
      on_subscribed.()
    end

    deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, 0)

    try do
      await_completion_loop(deadline_ms, "")
    after
      _ = Bus.unsubscribe(topic)
    end
  end

  defp await_completion_loop(deadline_ms, acc_answer) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      receive do
        %LemonCore.Event{type: :delta, payload: payload} ->
          delta = delta_text(payload)
          await_completion_loop(deadline_ms, acc_answer <> delta)

        %LemonCore.Event{type: :run_completed, payload: payload} ->
          {:ok, normalize_completion(payload, acc_answer)}

        _ ->
          await_completion_loop(deadline_ms, acc_answer)
      after
        remaining_ms ->
          {:error, :timeout}
      end
    end
  end

  defp normalize_completion(payload, acc_answer) when is_map(payload) do
    completed =
      payload[:completed] ||
        payload["completed"] ||
        payload

    ok = Map.get(completed, :ok, Map.get(completed, "ok", true))
    answer = Map.get(completed, :answer, Map.get(completed, "answer", acc_answer || ""))
    error = Map.get(completed, :error, Map.get(completed, "error"))
    duration_ms = payload[:duration_ms] || payload["duration_ms"]

    %{
      ok: ok != false,
      answer: normalize_answer(answer, acc_answer),
      error: error,
      duration_ms: duration_ms
    }
  end

  defp normalize_completion(_payload, acc_answer) do
    %{ok: true, answer: acc_answer || "", error: nil, duration_ms: nil}
  end

  defp completion_from_summary(summary) when is_map(summary) do
    completed = summary[:completed] || summary["completed"]

    if is_map(completed) do
      normalize_completion(%{completed: completed}, "")
    else
      nil
    end
  end

  defp completion_from_summary(_), do: nil

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

      TaskStore.finish(task_id, result)
    else
      TaskStore.fail(task_id, %{
        status: "error",
        error: completion.error,
        answer: completion.answer,
        details: details
      })
    end
  end

  defp auto_followup_text(completion, run_id, target_agent_id) do
    base = "[agent #{target_agent_id}] delegated run #{run_id}"

    cond do
      completion.ok and String.trim(completion.answer || "") == "" ->
        "#{base} completed with no textual answer."

      completion.ok ->
        "#{base} completed.\n\n#{completion.answer}"

      String.trim(completion.answer || "") == "" ->
        "#{base} failed: #{format_error(completion.error)}"

      true ->
        "#{base} failed: #{format_error(completion.error)}\n\nPartial output:\n#{completion.answer}"
    end
  end

  defp validate_run_params(params) when is_map(params) do
    agent_id = Map.get(params, "agent_id") |> normalize_optional_string()
    prompt = Map.get(params, "prompt")
    description = Map.get(params, "description") |> normalize_optional_string()
    async? = Map.get(params, "async", true)
    auto_followup = Map.get(params, "auto_followup", true)
    continue_session = Map.get(params, "continue_session", true)
    explicit_session_key = Map.get(params, "session_key") |> normalize_optional_string()
    queue_mode = Map.get(params, "queue_mode", "collect")
    timeout_ms = Map.get(params, "timeout_ms", @default_sync_timeout_ms)
    tool_policy = Map.get(params, "tool_policy")
    meta = Map.get(params, "meta")
    cwd = Map.get(params, "cwd")
    engine_id = Map.get(params, "engine_id")
    model = Map.get(params, "model")

    cond do
      not is_binary(agent_id) ->
        {:error, "agent_id is required and must be a non-empty string"}

      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "prompt is required and must be a non-empty string"}

      not is_boolean(async?) ->
        {:error, "async must be a boolean"}

      not is_boolean(auto_followup) ->
        {:error, "auto_followup must be a boolean"}

      not is_boolean(continue_session) ->
        {:error, "continue_session must be a boolean"}

      not is_nil(explicit_session_key) and not SessionKey.valid?(explicit_session_key) ->
        {:error, "session_key must be a valid Lemon session key"}

      not valid_queue_mode?(queue_mode) ->
        {:error, "queue_mode must be one of: #{Enum.join(@valid_queue_modes, ", ")}"}

      not valid_timeout_ms?(timeout_ms) ->
        {:error, "timeout_ms must be a non-negative integer"}

      not is_nil(tool_policy) and not is_map(tool_policy) ->
        {:error, "tool_policy must be an object"}

      not is_nil(meta) and not is_map(meta) ->
        {:error, "meta must be an object"}

      not is_nil(cwd) and not is_binary(cwd) ->
        {:error, "cwd must be a string"}

      not is_nil(engine_id) and not is_binary(engine_id) ->
        {:error, "engine_id must be a string"}

      not is_nil(model) and not is_binary(model) ->
        {:error, "model must be a string"}

      true ->
        {:ok,
         %{
           agent_id: agent_id,
           prompt: prompt,
           description: description || "Delegated run for #{agent_id}",
           async: async?,
           auto_followup: auto_followup,
           continue_session: continue_session,
           explicit_session_key: explicit_session_key,
           queue_mode: normalize_queue_mode(queue_mode),
           timeout_ms: timeout_ms,
           tool_policy: tool_policy,
           meta: meta || %{},
           cwd: cwd,
           engine_id: engine_id,
           model: normalize_optional_string(model)
         }}
    end
  end

  defp validate_run_params(_), do: {:error, "params must be an object"}

  defp resolve_delegated_session_key(%{explicit_session_key: key}, _opts) when is_binary(key),
    do: {:ok, key}

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

  defp build_poll_result(task_id, record, events) do
    status = Map.get(record, :status, :unknown)

    case status do
      :completed ->
        result = Map.get(record, :result)

        if match?(%AgentToolResult{}, result) do
          %AgentToolResult{
            content: result.content,
            details:
              result.details
              |> Map.put(:task_id, task_id)
              |> Map.put(:events, Enum.take(events, -5))
          }
        else
          %AgentToolResult{
            content: [%TextContent{text: "Delegated run completed."}],
            details: %{
              task_id: task_id,
              status: "completed",
              result: result,
              events: Enum.take(events, -5)
            }
          }
        end

      :error ->
        error = Map.get(record, :error)

        %AgentToolResult{
          content: [%TextContent{text: "Delegated run failed: #{format_error(error)}"}],
          details: %{
            task_id: task_id,
            status: "error",
            error: error,
            events: Enum.take(events, -5)
          }
        }

      other ->
        %AgentToolResult{
          content: [%TextContent{text: "Delegated run status: #{other}"}],
          details: %{
            task_id: task_id,
            status: to_string(other),
            run_id: Map.get(record, :run_id),
            agent_id: Map.get(record, :agent_id),
            session_key: Map.get(record, :delegated_session_key),
            events: Enum.take(events, -5)
          }
        }
    end
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
      "interrupt" -> :interrupt
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

  defp format_error(nil), do: "unknown"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp build_description do
    """
    Delegate work to another Lemon agent. **PREFERRED for most work** - use this instead of doing tasks yourself.

    **Default behavior (recommended):** async=true means the task runs in background and notifies you when done. This keeps the user conversation flowing smoothly without blocking.

    **Agent selection:**
    - Default: use the same agent_id as the current session (matches your profile/capabilities)
    - Specialized tasks: choose a different agent if the work requires different tools/privileges
    - Review/oracle patterns: delegate to a specific agent for independent verification

    **Usage patterns:**
    - Fire-and-forget: async=true, auto_followup=true (you'll get notified when done)
    - Check later: async=true, then poll with action=poll and task_id
    - Wait for result: async=false (blocks until completion - use sparingly for simple/quick tasks only)

    **Key parameters:**
    - async: true (default) = non-blocking, false = blocking/wait
    - auto_followup: true (default) = completion forwards back to this session
    - queue_mode: collect (default), followup, steer, steer_backlog, interrupt
    - model: optional model override (e.g., "gemini-2.5-pro" for complex tasks)

    Use this tool liberally to parallelize work and keep user interactions responsive.
    """
    |> String.trim()
  end

  defp build_agent_id_property(cwd, opts) do
    ids = resolve_available_agent_ids(cwd, opts)

    base = %{
      "type" => "string",
      "description" => "Target agent id for action=run. DEFAULT: use the same agent_id as this session (inherits your profile, tools, and capabilities)."
    }

    if ids == [] do
      base
    else
      base
      |> Map.put("enum", ids)
      |> Map.put(
        "description",
        "Target agent id for action=run. Available: #{Enum.join(ids, ", ")}"
      )
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

  defp normalize_agent_ids(_), do: ["default"]

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
end
