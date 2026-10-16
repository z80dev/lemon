defmodule CodingAgent.Tools.Task.Runner do
  @moduledoc false

  alias CodingAgent.Session
  alias CodingAgent.Tools.Task.{Control, Result}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @await_poll_ms 200
  @default_task_session_timeout_ms nil
  @output_retries 2
  @max_correction_error_chars 1_000

  @spec start_session_with_prompt(
          keyword(),
          String.t(),
          String.t(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t() | nil,
          keyword()
        ) :: AgentToolResult.t() | {:error, String.t()}
  def start_session_with_prompt(
        start_opts,
        prompt,
        description,
        signal,
        on_update,
        role_id,
        opts \\ []
      ) do
    case CodingAgent.start_session(start_opts) do
      {:ok, session} ->
        run_session(session, start_opts, prompt, description, signal, on_update, role_id, opts)

      {:error, reason} ->
        {:error, "Failed to start task session: #{inspect(reason)}"}
    end
  end

  @doc false
  def resume_session(session, resume, prompt, signal, on_update) do
    if is_pid(session) and Process.alive?(session) do
      run_session(
        session,
        resume.start_opts,
        prompt,
        resume.description,
        signal,
        on_update,
        resume.role_id,
        resume.opts
      )
    else
      start_session_with_prompt(
        resume.start_opts,
        prompt,
        resume.description,
        signal,
        on_update,
        resume.role_id,
        resume.opts
      )
    end
  end

  defp run_session(session, start_opts, prompt, description, signal, on_update, role_id, opts) do
    session_id = Session.get_stats(session).session_id
    on_update = with_session_id(on_update, session_id)
    session_ref = Process.monitor(session)
    timeout_ms = task_session_timeout_ms(opts)
    deadline_ms = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms

    try do
      result =
        with :ok <- attach_control_session(opts[:task_id], session, session_id) do
          await = fn next_prompt, budget ->
            {unsubscribe, delivery} = Session.subscribe(session, tagged: true)

            try do
              # Each prompt owns a fresh delivery gate. Old events remain fenced
              # even when they arrive after this mailbox drain.
              flush_session_events(session_id)

              with :ok <- prompt_idle_session(session, next_prompt) do
                await_result(
                  session,
                  session_ref,
                  delivery.gate,
                  session_id,
                  signal,
                  on_update,
                  description,
                  "",
                  "",
                  role_id,
                  timeout_ms,
                  deadline_ms,
                  task_session_poll_ms(opts),
                  budget
                )
              end
            after
              drain_session(session, session_ref, session_id, delivery.gate)
              unsubscribe.()
            end
          end

          details = %{
            session_id: session_id,
            description: description,
            status: "completed",
            role: role_id
          }

          budget = %{
            limit: Keyword.get(opts, :request_budget, 200),
            notice: Keyword.get(opts, :request_budget_notice, true),
            count: 0
          }

          await_valid_result(
            await,
            prompt,
            details,
            opts[:validate_output],
            @output_retries,
            budget
          )
        end

      unless retain_session(result, session, start_opts, description, role_id, opts),
        do: stop_session(session)

      result
    catch
      kind, reason ->
        stop_session(session)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.demonitor(session_ref, [:flush])
    end
  end

  defp retain_session(%AgentToolResult{}, session, start_opts, description, role_id, opts) do
    if opts[:task_id] && Session.save(session) == :ok do
      state = Session.get_state(session)

      resume = %{
        start_opts:
          start_opts
          |> Keyword.put(:session_file, state.session_file)
          |> Keyword.put(:model, state.model)
          |> Keyword.put(:thinking_level, state.thinking_level),
        description: description,
        role_id: role_id,
        opts: opts
      }

      Control.retain_session(opts[:task_id], session, resume) == :ok
    else
      false
    end
  end

  defp retain_session(_result, _session, _start_opts, _description, _role_id, _opts),
    do: false

  # Re-prompts the same child session when its final output fails the caller's
  # validator. After the retries are spent, the last result is returned and the
  # caller decides whether invalid output fails the task.
  defp await_valid_result(await, prompt, details, validator, retries_left, budget) do
    with {:ok, %{text: text, thinking: thinking} = payload, budget} <- await.(prompt, budget) do
      result = %AgentToolResult{
        content: Result.build_update_content(text, thinking),
        details: Map.merge(details, Map.get(payload, :details, %{}))
      }

      case {result.details[:budget_exhausted], validate_result(validator, result)} do
        {exhausted, {:error, reason}} when exhausted != true and retries_left > 0 ->
          await_valid_result(
            await,
            correction_prompt(reason),
            details,
            validator,
            retries_left - 1,
            budget
          )

        _ ->
          result
      end
    end
  end

  defp flush_session_events(session_id) do
    receive do
      {:session_event, ^session_id, _event} ->
        flush_session_events(session_id)

      {:session_terminal, ^session_id, _status} ->
        flush_session_events(session_id)

      {:lemon_bus_delivery, _gate, {:session_event, ^session_id, _event}} ->
        flush_session_events(session_id)

      {:lemon_bus_delivery, _gate, {:session_terminal, ^session_id, _status}} ->
        flush_session_events(session_id)
    after
      0 -> :ok
    end
  end

  defp await_session_event(session_ref, delivery_gate, session_id, timeout) do
    receive do
      {:lemon_bus_delivery, ^delivery_gate, {:session_event, ^session_id, _event} = event} ->
        event

      {:lemon_bus_delivery, ^delivery_gate, {:session_terminal, ^session_id, _status} = event} ->
        event

      {:DOWN, ^session_ref, :process, _pid, _reason} = event ->
        event
    after
      timeout -> :timeout
    end
  end

  defp validate_result(validator, result) when is_function(validator, 1),
    do: validator.(Result.visible_output_text(result))

  defp validate_result(_validator, _result), do: :ok

  defp correction_prompt(reason) do
    reason = if is_binary(reason), do: reason, else: inspect(reason)

    reason =
      if String.length(reason) > @max_correction_error_chars,
        do: String.slice(reason, 0, @max_correction_error_chars) <> "...",
        else: reason

    "Your final response failed validation against the required output schema: #{reason}\n" <>
      "Reply again with ONLY the corrected JSON value that satisfies the schema; " <>
      "no Markdown fences, explanations, or other prose."
  end

  # The terminal event can reach subscribers just before the session records
  # itself idle, so a brief already-streaming window is retried.
  defp prompt_idle_session(session, text, attempts \\ 50) do
    case Session.prompt(session, text) do
      {:error, :already_streaming} when attempts > 0 ->
        Process.sleep(20)
        prompt_idle_session(session, text, attempts - 1)

      {:error, :already_streaming} ->
        {:error, "Task session is already running"}

      other ->
        other
    end
  end

  defp attach_control_session(nil, _session, _session_id), do: :ok

  defp attach_control_session(task_id, session, session_id),
    do: Control.attach_session(task_id, session, session_id)

  defp await_result(
         session,
         session_ref,
         delivery_gate,
         session_id,
         signal,
         on_update,
         description,
         last_text,
         last_thinking,
         role_id,
         timeout_ms,
         deadline_ms,
         poll_ms,
         budget
       ) do
    case await_session_event(
           session_ref,
           delivery_gate,
           session_id,
           await_timeout(deadline_ms, poll_ms)
         ) do
      {:session_terminal, ^session_id, status} ->
        case Session.get_state(session).terminal_event do
          {:agent_end, messages} ->
            completed_result(messages, signal, last_text, last_thinking, budget)

          {:error, reason, _partial_state} ->
            {:error, reason}

          {:canceled, _reason} ->
            {:error, "Task aborted"}

          {:turn_end, %{stop_reason: :aborted}, _tool_results} ->
            {:error, "Task aborted"}

          _ when status == :canceled ->
            {:error, "Task aborted"}

          _ when status == :error ->
            {:error, "Task session failed"}

          _ ->
            completed_result(
              Session.get_messages(session),
              signal,
              last_text,
              last_thinking,
              budget
            )
        end

      {:DOWN, ^session_ref, :process, _pid, reason} ->
        {:error, format_session_exit(reason)}

      {:session_event, ^session_id, {:tool_execution_start, _id, name, args}} ->
        maybe_emit_action_update(
          on_update,
          description,
          internal_tool_title(name, args),
          internal_tool_kind(name),
          "started",
          args
        )

        await_result(
          session,
          session_ref,
          delivery_gate,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          role_id,
          timeout_ms,
          deadline_ms,
          poll_ms,
          budget
        )

      {:session_event, ^session_id, {:tool_execution_update, _id, name, args, partial_result}} ->
        maybe_forward_descendant_update(on_update, name, partial_result)

        maybe_emit_action_update(
          on_update,
          description,
          internal_tool_title(name, args),
          internal_tool_kind(name),
          "updated",
          args
        )

        await_result(
          session,
          session_ref,
          delivery_gate,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          role_id,
          timeout_ms,
          deadline_ms,
          poll_ms,
          budget
        )

      {:session_event, ^session_id, {:tool_execution_end, _id, name, result, is_error}} ->
        maybe_emit_action_update(
          on_update,
          description,
          "#{if is_error, do: "Failed", else: "Completed"}: #{name}",
          internal_tool_kind(name),
          if(is_error, do: "error", else: "completed"),
          %{name: name, result: result}
        )

        await_result(
          session,
          session_ref,
          delivery_gate,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          role_id,
          timeout_ms,
          deadline_ms,
          poll_ms,
          budget
        )

      {:session_event, ^session_id,
       {:message_update, %LemonAi.Types.AssistantMessage{} = msg, _event}} ->
        text = LemonAi.get_text(msg)
        thinking = LemonAi.get_thinking(msg)

        {last_text, last_thinking} =
          maybe_emit_update(
            on_update,
            text,
            thinking,
            last_text,
            last_thinking,
            description,
            session_id,
            role_id
          )

        await_result(
          session,
          session_ref,
          delivery_gate,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          role_id,
          timeout_ms,
          deadline_ms,
          poll_ms,
          budget
        )

      {:session_event, ^session_id, {:message_end, %LemonAi.Types.AssistantMessage{} = msg}} ->
        text = LemonAi.get_text(msg)
        thinking = LemonAi.get_thinking(msg)

        {last_text, last_thinking} =
          maybe_emit_update(
            on_update,
            text,
            thinking,
            last_text,
            last_thinking,
            description,
            session_id,
            role_id
          )

        budget = %{budget | count: budget.count + 1}

        if budget.limit > 0 and budget.count >= div(3 * budget.limit + 1, 2) do
          Session.abort(session)
          drain_session(session, session_ref, session_id, delivery_gate)

          {:ok,
           %{
             text: text <> "\n\nTask stopped at request budget #{budget.count} (partial output).",
             thinking: thinking,
             details: %{
               budget_exhausted: true,
               partial: true,
               partial_output: text,
               request_count: budget.count,
               request_budget: budget.limit
             }
           }, budget}
        else
          if budget.limit > 0 and budget.count == budget.limit and budget.notice do
            Session.steer(
              session,
              "You have reached your request budget (#{budget.limit}). Wrap up now: " <>
                "summarize your findings and return your final answer; avoid further exploration."
            )
          end

          await_result(
            session,
            session_ref,
            delivery_gate,
            session_id,
            signal,
            on_update,
            description,
            last_text,
            last_thinking,
            role_id,
            timeout_ms,
            deadline_ms,
            poll_ms,
            budget
          )
        end

      {:session_event, ^session_id, {:agent_end, messages}} ->
        completed_result(messages, signal, last_text, last_thinking, budget)

      {:session_event, ^session_id, {:error, reason, _partial_state}} ->
        {:error, reason}

      {:session_event, ^session_id, {:canceled, _reason}} ->
        {:error, "Task aborted"}

      {:session_event, ^session_id, _event} ->
        await_result(
          session,
          session_ref,
          delivery_gate,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          role_id,
          timeout_ms,
          deadline_ms,
          poll_ms,
          budget
        )

      :timeout ->
        if AbortSignal.aborted?(signal) do
          Session.abort(session)
          {:error, "Task aborted"}
        else
          case remaining_task_session_ms(deadline_ms) do
            remaining when remaining <= 0 ->
              Session.abort(session)
              {:error, task_session_timeout_error(timeout_ms)}

            _remaining ->
              await_result(
                session,
                session_ref,
                delivery_gate,
                session_id,
                signal,
                on_update,
                description,
                last_text,
                last_thinking,
                role_id,
                timeout_ms,
                deadline_ms,
                poll_ms,
                budget
              )
          end
        end
    end
  end

  defp completed_result(messages, signal, last_text, last_thinking, budget) do
    messages =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(Map.get(&1, :role) != :user))
      |> Enum.reverse()

    last = messages |> Enum.filter(&match?(%LemonAi.Types.AssistantMessage{}, &1)) |> List.last()

    cond do
      AbortSignal.aborted?(signal) ->
        {:error, "Task aborted"}

      last && last.stop_reason in [:error, :aborted, :length] ->
        {:error, last.error_message || "Task stopped: #{last.stop_reason}"}

      true ->
        {:ok, Result.extract_final_payload(messages, last_text, last_thinking), budget}
    end
  end

  defp task_session_timeout_ms(opts) do
    case Keyword.get(opts, :task_session_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_task_session_timeout_ms
    end
  end

  defp task_session_poll_ms(opts) do
    case Keyword.get(opts, :task_session_poll_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @await_poll_ms
    end
  end

  defp remaining_task_session_ms(nil), do: :infinity

  defp remaining_task_session_ms(deadline_ms) do
    deadline_ms - System.monotonic_time(:millisecond)
  end

  defp await_timeout(nil, poll_ms), do: poll_ms

  defp await_timeout(deadline_ms, poll_ms) do
    remaining_task_session_ms(deadline_ms)
    |> min(poll_ms)
    |> max(0)
  end

  defp task_session_timeout_error(nil), do: "Task session timed out waiting for completion"

  defp task_session_timeout_error(timeout_ms) do
    "Task session timed out after #{timeout_ms}ms waiting for completion"
  end

  defp format_session_exit(:normal), do: "Task session exited before completion"
  defp format_session_exit(:shutdown), do: "Task session exited before completion"
  defp format_session_exit({:shutdown, _}), do: "Task session exited before completion"

  defp format_session_exit(reason) do
    "Task session crashed before completion: #{inspect(reason)}"
  end

  defp maybe_forward_descendant_update(
         callback,
         "task",
         %AgentToolResult{details: %{task_id: task_id}} = result
       )
       when is_function(callback, 1) and is_binary(task_id),
       do: callback.(result)

  defp maybe_forward_descendant_update(_callback, _name, _result), do: :ok

  defp maybe_emit_action_update(nil, _description, _text, _kind, _phase, _detail), do: :ok

  defp maybe_emit_action_update(on_update, description, text, kind, phase, detail) do
    extra_details = %{
      current_action: %{title: text, kind: to_string(kind), phase: phase}
    }

    extra_details =
      if is_map(detail) and map_size(detail) > 0 do
        Map.put(extra_details, :action_detail, detail)
      else
        extra_details
      end

    on_update.(%AgentToolResult{
      content: [%TextContent{text: text}],
      details:
        %{
          description: description,
          status: "running"
        }
        |> Map.merge(extra_details)
    })
  end

  defp maybe_emit_update(
         nil,
         _text,
         _thinking,
         last_text,
         last_thinking,
         _description,
         _session_id,
         _role_id
       ) do
    {last_text, last_thinking}
  end

  defp maybe_emit_update(
         on_update,
         text,
         thinking,
         last_text,
         _last_thinking,
         description,
         session_id,
         role_id
       ) do
    if text != "" and text != last_text do
      details =
        %{
          session_id: session_id,
          description: description,
          status: "running",
          role: role_id
        }

      on_update.(%AgentToolResult{
        content: Result.build_update_content(text, thinking),
        details: details
      })
    end

    {text, thinking}
  end

  defp with_session_id(nil, _session_id), do: nil

  defp with_session_id(callback, session_id) do
    fn result ->
      callback.(%{result | details: Map.put_new(result.details || %{}, :session_id, session_id)})
    end
  end

  defp drain_session(session, session_ref, session_id, delivery_gate) do
    if Process.alive?(session) and Session.get_state(session).is_streaming do
      Session.abort(session)

      await_shutdown(
        session_ref,
        session_id,
        delivery_gate,
        System.monotonic_time(:millisecond) + 1_000
      )
    end
  catch
    :exit, _ -> :ok
  end

  defp await_shutdown(session_ref, session_id, delivery_gate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case await_session_event(session_ref, delivery_gate, session_id, remaining) do
      {:DOWN, ^session_ref, :process, _, _} ->
        :ok

      {:session_terminal, ^session_id, _status} ->
        :ok

      {:session_event, ^session_id, {:agent_end, _}} ->
        :ok

      {:session_event, ^session_id, {:canceled, _}} ->
        :ok

      {:session_event, ^session_id, {:error, _, _}} ->
        :ok

      {:session_event, ^session_id, _} ->
        await_shutdown(session_ref, session_id, delivery_gate, deadline)

      :timeout ->
        :ok
    end
  end

  defp stop_session(session) when is_pid(session) do
    try do
      if Process.whereis(CodingAgent.SessionSupervisor) do
        _ = CodingAgent.SessionSupervisor.stop_session(session)
      else
        GenServer.stop(session, :normal, 5_000)
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  defp internal_tool_kind(name) do
    case String.downcase(name || "") do
      "bash" -> :command
      "read" -> :tool
      "write" -> :file_change
      "edit" -> :file_change
      "glob" -> :tool
      "grep" -> :tool
      "websearch" -> :web_search
      "webfetch" -> :web_search
      "browser_" <> _ -> :browser
      "task" -> :subagent
      "agent" -> :subagent
      "cron" -> :subagent
      _ -> :tool
    end
  end

  defp internal_tool_title(name, args) do
    a = stringify_keys(args)

    case String.downcase(name || "") do
      "bash" ->
        cmd = a["command"] || ""
        cmd_preview = cmd |> String.split("\n") |> hd() |> String.slice(0, 60)
        "`#{cmd_preview}`"

      "read" ->
        path = a["path"] || a["file_path"] || ""
        "read: `#{path_label(path)}`"

      "write" ->
        path = a["path"] || a["file_path"] || ""
        "write: `#{path_label(path)}`"

      "edit" ->
        path = a["path"] || a["file_path"] || ""
        "edit: `#{path_label(path)}`"

      "glob" ->
        "glob: `#{a["pattern"] || ""}`"

      "grep" ->
        pattern = String.slice(a["pattern"] || "", 0, 30)
        path = a["path"]

        if is_binary(path) and path != "" do
          "grep: `#{pattern}` in #{path_label(path)}"
        else
          "grep: `#{pattern}`"
        end

      "websearch" ->
        "search: #{String.slice(a["query"] || "", 0, 50)}"

      "webfetch" ->
        "fetch: #{String.slice(a["url"] || "", 0, 50)}"

      "browser_navigate" ->
        "browser: #{String.slice(a["url"] || "", 0, 50)}"

      "browser_click" ->
        "browser click: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_type" ->
        "browser type: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_hover" ->
        "browser hover: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_select_option" ->
        "browser select option: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_upload_file" ->
        "browser upload file"

      "browser_download" ->
        "browser download"

      "browser_press" ->
        "browser key: #{String.slice(a["key"] || "", 0, 30)}"

      "browser_scroll" ->
        "browser scroll"

      "browser_back" ->
        "browser back"

      "browser_events" ->
        "browser events"

      "browser_get_cookies" ->
        "browser cookies"

      "browser_set_cookies" ->
        "browser set cookies"

      "browser_clear_state" ->
        "browser clear state"

      "browser_snapshot" ->
        "browser snapshot"

      "browser_get_content" ->
        "browser content"

      "browser_wait_for_selector" ->
        "browser wait"

      "browser_evaluate" ->
        "browser evaluate"

      "browser_screenshot" ->
        "browser screenshot"

      "task" ->
        "task: #{String.slice(a["description"] || a["prompt"] || "", 0, 50)}"

      "agent" ->
        "agent: #{String.slice(a["prompt"] || a["description"] || "", 0, 50)}"

      "cron" ->
        "cron: #{String.slice(a["prompt"] || "", 0, 50)}"

      n ->
        n
    end
  end

  defp path_label(path) when is_binary(path) do
    parts = Path.split(path)

    case length(parts) do
      n when n > 2 -> Path.join(Enum.take(parts, -2))
      _ -> path
    end
  end

  defp path_label(other), do: inspect(other)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(_), do: %{}
end
