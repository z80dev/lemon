defmodule LemonAgent.Loop.ToolCalls do
  @moduledoc false

  alias LemonAgent.AbortSignal
  alias LemonAgent.EventStream
  alias LemonAgent.Types.{AgentLoopConfig, AgentToolResult}

  alias LemonAi.Types.{
    TextContent,
    ToolResultMessage
  }

  @tool_abort_grace_ms 250

  @unicode_whitespace for codepoint <- [
                            0x00A0,
                            0x2000,
                            0x2001,
                            0x2002,
                            0x2003,
                            0x2004,
                            0x2005,
                            0x2006,
                            0x2007,
                            0x2008,
                            0x2009,
                            0x200A,
                            0x202F,
                            0x205F,
                            0x3000
                          ],
                          into: "",
                          do: <<codepoint::utf8>>
  @whitespace_pattern Regex.compile!("[\\s" <> @unicode_whitespace <> "]+", "u")

  @spec execute_and_collect_tools(
          LemonAgent.Types.AgentContext.t(),
          [LemonAgent.Types.agent_message()],
          [LemonAi.Types.ToolCall.t()],
          AgentLoopConfig.t(),
          reference() | nil,
          EventStream.t()
        ) ::
          {[ToolResultMessage.t()], [LemonAgent.Types.agent_message()],
           LemonAgent.Types.AgentContext.t(), [LemonAgent.Types.agent_message()]}
  def execute_and_collect_tools(context, new_messages, tool_calls, config, signal, stream) do
    {results, steering_messages, context, new_messages} =
      execute_tool_calls(context, new_messages, tool_calls, config, signal, stream)

    {results, steering_messages, context, new_messages}
  end

  defp execute_tool_calls(context, new_messages, tool_calls, config, signal, stream) do
    {results, context, new_messages} =
      execute_tool_calls_parallel(context, new_messages, tool_calls, config, signal, stream)

    steering_messages =
      if aborted?(signal) do
        []
      else
        # Clear before draining so a redirect received during this batch does
        # not cancel the next model call after its correction is consumed.
        AbortSignal.clear_redirect(signal)
        get_steering_messages(config)
      end

    {results, steering_messages, context, new_messages}
  end

  defp execute_tool_calls_parallel(context, new_messages, tool_calls, config, signal, stream) do
    max_concurrency = resolve_max_tool_concurrency(config, length(tool_calls))
    tool_timeout_ms = resolve_tool_timeout_ms(config)
    tool_task_supervisor = config.tool_task_supervisor || LemonAgent.ToolTaskSupervisor
    tool_call_order = tool_call_order(tool_calls)
    base_context_message_count = length(context.messages)
    base_new_message_count = length(new_messages)

    pending_by_ref = %{}
    pending_by_mon = %{}
    remaining_tool_calls = tool_calls
    results = []

    collect_parallel_tool_results(
      context,
      new_messages,
      pending_by_ref,
      pending_by_mon,
      remaining_tool_calls,
      context.tools,
      tool_task_supervisor,
      max_concurrency,
      tool_timeout_ms,
      results,
      stream,
      signal,
      tool_call_order,
      base_context_message_count,
      base_new_message_count,
      config
    )
  end

  defp collect_parallel_tool_results(
         context,
         new_messages,
         pending_by_ref,
         pending_by_mon,
         remaining_tool_calls,
         tools,
         tool_task_supervisor,
         max_concurrency,
         tool_timeout_ms,
         results,
         stream,
         signal,
         tool_call_order,
         base_context_message_count,
         base_new_message_count,
         config
       ) do
    cond do
      aborted?(signal) ->
        aborted_tasks = stop_aborted_tools(pending_by_ref, pending_by_mon, tool_task_supervisor)

        {context, new_messages, results} =
          Enum.reduce(aborted_tasks, {context, new_messages, results}, fn {_ref, pending},
                                                                          {ctx, messages,
                                                                           collected} ->
            {result, is_error} = aborted_task_result(pending)
            tool_call_finish(pending.tool_call.name, pending.started_at, result, is_error)

            LemonCore.Telemetry.emit(
              [:lemon_agent, :tool_task, :end],
              %{system_time: System.system_time()},
              %{
                tool_name: pending.tool_call.name,
                tool_call_id: pending.tool_call.id,
                is_error: is_error
              }
            )

            emit_tool_result(
              pending.tool_call,
              result,
              is_error,
              ctx,
              messages,
              collected,
              stream
            )
          end)

        {context, new_messages, results} =
          emit_tool_errors(
            remaining_tool_calls,
            tool_aborted_result(nil, false),
            context,
            new_messages,
            results,
            stream
          )

        finish_tool_results(
          results,
          context,
          new_messages,
          tool_call_order,
          base_context_message_count,
          base_new_message_count
        )

      map_size(pending_by_ref) == 0 and remaining_tool_calls == [] ->
        finish_tool_results(
          results,
          context,
          new_messages,
          tool_call_order,
          base_context_message_count,
          base_new_message_count
        )

      true ->
        {context, new_messages, results, remaining_tool_calls} =
          if remaining_tool_calls != [] and has_steering_messages?(config) and
               not aborted?(signal) do
            {context, new_messages, results} =
              emit_tool_errors(
                remaining_tool_calls,
                tool_skipped_result(),
                context,
                new_messages,
                results,
                stream
              )

            {context, new_messages, results, []}
          else
            {context, new_messages, results, remaining_tool_calls}
          end

        {pending_by_ref, pending_by_mon, remaining_tool_calls, start_failures} =
          start_tool_tasks(
            tools,
            remaining_tool_calls,
            pending_by_ref,
            pending_by_mon,
            max_concurrency - map_size(pending_by_ref),
            tool_timeout_ms,
            signal,
            stream,
            tool_task_supervisor,
            config
          )

        {context, new_messages, results} =
          emit_start_failures(start_failures, context, new_messages, results, stream)

        {context, new_messages, pending_by_ref, pending_by_mon, results} =
          if map_size(pending_by_ref) == 0 do
            {context, new_messages, pending_by_ref, pending_by_mon, results}
          else
            receive do
              {:tool_task_update, ref, partial} ->
                pending_by_ref = remember_partial(pending_by_ref, ref, partial)
                {context, new_messages, pending_by_ref, pending_by_mon, results}

              {:tool_task_result, ref, tool_call, result, is_error} ->
                if Map.has_key?(pending_by_ref, ref) do
                  pending = Map.fetch!(pending_by_ref, ref)
                  tool_call_finish(tool_call.name, pending.started_at, result, is_error)

                  {pending_by_ref, pending_by_mon} =
                    drop_pending_task(pending_by_ref, pending_by_mon, ref)

                  LemonCore.Telemetry.emit(
                    [:lemon_agent, :tool_task, :end],
                    %{system_time: System.system_time()},
                    %{tool_name: tool_call.name, tool_call_id: tool_call.id, is_error: is_error}
                  )

                  {context, new_messages, results} =
                    emit_tool_result(
                      tool_call,
                      result,
                      is_error,
                      context,
                      new_messages,
                      results,
                      stream
                    )

                  {context, new_messages, pending_by_ref, pending_by_mon, results}
                else
                  {context, new_messages, pending_by_ref, pending_by_mon, results}
                end

              {:DOWN, mon_ref, :process, _pid, reason} ->
                case Map.get(pending_by_mon, mon_ref) do
                  nil ->
                    {context, new_messages, pending_by_ref, pending_by_mon, results}

                  ref ->
                    %{tool_call: tool_call} = pending = Map.fetch!(pending_by_ref, ref)
                    result = tool_crash_result(reason)
                    tool_call_finish(tool_call.name, pending.started_at, result, true)

                    {pending_by_ref, pending_by_mon} =
                      drop_pending_task(pending_by_ref, pending_by_mon, ref)

                    LemonCore.Telemetry.emit(
                      [:lemon_agent, :tool_task, :error],
                      %{system_time: System.system_time()},
                      %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: reason}
                    )

                    {context, new_messages, results} =
                      emit_tool_result(
                        tool_call,
                        result,
                        true,
                        context,
                        new_messages,
                        results,
                        stream
                      )

                    {context, new_messages, pending_by_ref, pending_by_mon, results}
                end

              {:tool_task_timeout, ref} ->
                case Map.get(pending_by_ref, ref) do
                  nil ->
                    {context, new_messages, pending_by_ref, pending_by_mon, results}

                  %{tool_call: tool_call, pid: pid, timeout_ms: timeout_ms} = pending ->
                    result = tool_timeout_result(timeout_ms)
                    tool_call_finish(tool_call.name, pending.started_at, result, true)

                    {pending_by_ref, pending_by_mon} =
                      drop_pending_task(pending_by_ref, pending_by_mon, ref)

                    Task.Supervisor.terminate_child(tool_task_supervisor, pid)

                    LemonCore.Telemetry.emit(
                      [:lemon_agent, :tool_task, :error],
                      %{system_time: System.system_time()},
                      %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: :timeout}
                    )

                    {context, new_messages, results} =
                      emit_tool_result(
                        tool_call,
                        result,
                        true,
                        context,
                        new_messages,
                        results,
                        stream
                      )

                    {context, new_messages, pending_by_ref, pending_by_mon, results}
                end
            after
              100 ->
                # Poll steering without draining it, and abort without waiting
                # for a running tool to produce another event.
                {context, new_messages, pending_by_ref, pending_by_mon, results}
            end
          end

        collect_parallel_tool_results(
          context,
          new_messages,
          pending_by_ref,
          pending_by_mon,
          remaining_tool_calls,
          tools,
          tool_task_supervisor,
          max_concurrency,
          tool_timeout_ms,
          results,
          stream,
          signal,
          tool_call_order,
          base_context_message_count,
          base_new_message_count,
          config
        )
    end
  end

  defp tool_call_order(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Map.new(fn {tool_call, index} -> {tool_call.id, index} end)
  end

  defp finish_tool_results(
         results,
         context,
         new_messages,
         tool_call_order,
         base_context_message_count,
         base_new_message_count
       ) do
    results = order_tool_results(results, tool_call_order)

    context = %{
      context
      | messages:
          reorder_tool_result_tail(context.messages, base_context_message_count, tool_call_order)
    }

    new_messages =
      reorder_tool_result_tail(new_messages, base_new_message_count, tool_call_order)

    {results, context, new_messages}
  end

  defp order_tool_results(results, tool_call_order) do
    results
    |> Enum.reverse()
    |> Enum.sort_by(&tool_result_order(&1, tool_call_order))
  end

  defp reorder_tool_result_tail(messages, base_count, tool_call_order) do
    {prefix, suffix} = Enum.split(messages, base_count)
    prefix ++ Enum.sort_by(suffix, &tool_result_order(&1, tool_call_order))
  end

  defp tool_result_order(%ToolResultMessage{tool_call_id: tool_call_id}, tool_call_order) do
    {Map.get(tool_call_order, tool_call_id, map_size(tool_call_order)), tool_call_id || ""}
  end

  defp tool_result_order(_message, tool_call_order), do: {map_size(tool_call_order), ""}

  defp start_tool_tasks(
         _tools,
         remaining_tool_calls,
         pending_by_ref,
         pending_by_mon,
         available_slots,
         _tool_timeout_ms,
         _signal,
         _stream,
         _tool_task_supervisor,
         _config
       )
       when available_slots <= 0 do
    {pending_by_ref, pending_by_mon, remaining_tool_calls, []}
  end

  defp start_tool_tasks(
         tools,
         remaining_tool_calls,
         pending_by_ref,
         pending_by_mon,
         available_slots,
         tool_timeout_ms,
         signal,
         stream,
         tool_task_supervisor,
         config
       ) do
    unsafe_pending? =
      Enum.any?(pending_by_ref, fn {_ref, pending} -> not pending.parallel_safe end)

    if aborted?(signal) or has_steering_messages?(config) or unsafe_pending? do
      {pending_by_ref, pending_by_mon, remaining_tool_calls, []}
    else
      parent = self()
      max_pending = map_size(pending_by_ref) + available_slots

      {by_ref, by_mon, remaining, start_failures} =
        Enum.reduce_while(
          remaining_tool_calls,
          {pending_by_ref, pending_by_mon, remaining_tool_calls, []},
          fn tool_call, {by_ref, by_mon, remaining, start_failures} = state ->
            tool = find_tool(tools, tool_call.name)
            parallel_safe? = tool != nil and tool.parallel_safe == true

            cond do
              aborted?(signal) or has_steering_messages?(config) ->
                {:halt, state}

              map_size(by_ref) >= max_pending ->
                {:halt, state}

              not parallel_safe? and map_size(by_ref) > 0 ->
                # Unsafe calls are barriers: neither earlier nor later safe
                # calls may overlap their execution.
                {:halt, state}

              true ->
                [_tool_call | rest] = remaining
                started_at = tool_call_start(tool_call.name)

                EventStream.push(
                  stream,
                  {:tool_execution_start, tool_call.id, tool_call.name, tool_call.arguments}
                )

                ref = make_ref()

                LemonCore.Telemetry.emit(
                  [:lemon_agent, :tool_task, :start],
                  %{system_time: System.system_time()},
                  %{tool_name: tool_call.name, tool_call_id: tool_call.id}
                )

                case prepare_tool_call(tool, tool_call) do
                  {:ok, prepared_tool_call} ->
                    case start_tool_task(
                           tool_task_supervisor,
                           parent,
                           ref,
                           tool,
                           prepared_tool_call,
                           signal,
                           stream
                         ) do
                      {:ok, pid} ->
                        mon_ref = Process.monitor(pid)
                        timeout_ms = tool_timeout(tool, tool_timeout_ms)
                        timeout_ref = schedule_tool_timeout(ref, timeout_ms)

                        state = {
                          Map.put(by_ref, ref, %{
                            tool_call: prepared_tool_call,
                            started_at: started_at,
                            mon_ref: mon_ref,
                            pid: pid,
                            timeout_ref: timeout_ref,
                            timeout_ms: timeout_ms,
                            parallel_safe: parallel_safe?,
                            partial: nil,
                            result: nil
                          }),
                          Map.put(by_mon, mon_ref, ref),
                          rest,
                          start_failures
                        }

                        if parallel_safe?, do: {:cont, state}, else: {:halt, state}

                      {:error, reason} ->
                        LemonCore.Telemetry.emit(
                          [:lemon_agent, :tool_task, :error],
                          %{system_time: System.system_time()},
                          %{
                            tool_name: tool_call.name,
                            tool_call_id: tool_call.id,
                            reason: {:start_failed, reason}
                          }
                        )

                        result = tool_start_failure_result(reason)
                        tool_call_finish(tool_call.name, started_at, result, true)
                        failure = {tool_call, result}
                        {:cont, {by_ref, by_mon, rest, [failure | start_failures]}}
                    end

                  {:error, result} ->
                    tool_call_finish(tool_call.name, started_at, result, true)

                    LemonCore.Telemetry.emit(
                      [:lemon_agent, :tool_task, :error],
                      %{system_time: System.system_time()},
                      %{
                        tool_name: tool_call.name,
                        tool_call_id: tool_call.id,
                        reason: result.details.error_type
                      }
                    )

                    {:cont, {by_ref, by_mon, rest, [{tool_call, result} | start_failures]}}
                end
            end
          end
        )

      {by_ref, by_mon, remaining, Enum.reverse(start_failures)}
    end
  end

  defp start_tool_task(tool_task_supervisor, parent, ref, tool, tool_call, signal, stream) do
    Task.Supervisor.start_child(tool_task_supervisor, fn ->
      {result, is_error} = execute_tool_call(tool, tool_call, signal, stream, parent, ref)
      send(parent, {:tool_task_result, ref, tool_call, result, is_error})
    end)
  catch
    :exit, reason -> {:error, reason}
  else
    {:ok, pid} -> {:ok, pid}
    {:error, reason} -> {:error, reason}
    other -> {:error, {:unexpected_start_result, other}}
  end

  defp emit_start_failures(start_failures, context, new_messages, results, stream) do
    Enum.reduce(start_failures, {context, new_messages, results}, fn {tool_call, result},
                                                                     {acc_context,
                                                                      acc_new_messages,
                                                                      acc_results} ->
      emit_tool_result(
        tool_call,
        result,
        true,
        acc_context,
        acc_new_messages,
        acc_results,
        stream
      )
    end)
  end

  defp emit_tool_errors(tool_calls, result, context, new_messages, results, stream) do
    Enum.reduce(tool_calls, {context, new_messages, results}, fn tool_call,
                                                                 {context, new_messages, results} ->
      started_at = tool_call_start(tool_call.name)
      tool_call_finish(tool_call.name, started_at, result, true)

      LemonCore.Telemetry.emit(
        [:lemon_agent, :tool_task, :error],
        %{system_time: System.system_time()},
        %{
          tool_name: tool_call.name,
          tool_call_id: tool_call.id,
          reason: Map.get(result.details, :reason, result.details.error_type)
        }
      )

      emit_tool_result(tool_call, result, true, context, new_messages, results, stream)
    end)
  end

  defp tool_call_start(name) do
    started_at = System.monotonic_time()

    LemonCore.Telemetry.emit(
      [:lemon_agent, :tool_call, :start],
      %{system_time: System.system_time()},
      %{tool_name: name, is_error: false, timeout: false}
    )

    started_at
  end

  defp tool_call_finish(name, started_at, result, is_error) do
    details = if is_map(result.details), do: result.details, else: %{}
    error_type = Map.get(details, :error_type)

    timeout =
      error_type == :tool_task_timeout or
        Map.get(details, :timed_out) == true or Map.get(details, :timedOut) == true

    event =
      if error_type in [
           :tool_exception,
           :tool_caught,
           :tool_task_start_failed,
           :tool_task_crashed,
           :tool_task_timeout
         ], do: :exception, else: :stop

    LemonCore.Telemetry.emit(
      [:lemon_agent, :tool_call, event],
      %{duration: System.monotonic_time() - started_at},
      %{tool_name: name, is_error: is_error, timeout: timeout}
    )
  end

  defp drop_pending_task(pending_by_ref, pending_by_mon, ref) do
    case Map.pop(pending_by_ref, ref) do
      {nil, pending_by_ref} ->
        {pending_by_ref, pending_by_mon}

      {%{mon_ref: mon_ref, timeout_ref: timeout_ref}, pending_by_ref} ->
        Process.demonitor(mon_ref, [:flush])
        cancel_tool_timeout(timeout_ref)
        pending_by_mon = Map.delete(pending_by_mon, mon_ref)
        {pending_by_ref, pending_by_mon}
    end
  end

  defp emit_tool_result(tool_call, result, is_error, context, new_messages, results, stream) do
    EventStream.push(
      stream,
      {:tool_execution_end, tool_call.id, tool_call.name, result, is_error}
    )

    trust = normalize_trust(result.trust)

    tool_result_message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      content: result.content,
      details: result.details,
      trust: trust,
      is_error: is_error,
      timestamp: System.system_time(:millisecond)
    }

    context = %{context | messages: context.messages ++ [tool_result_message]}
    new_messages = new_messages ++ [tool_result_message]
    results = [tool_result_message | results]

    EventStream.push(stream, {:message_start, tool_result_message})
    EventStream.push(stream, {:message_end, tool_result_message})

    LemonCore.Telemetry.emit(
      [:lemon_agent, :tool_result, :emit],
      %{system_time: System.system_time()},
      %{
        tool_name: tool_call.name,
        tool_call_id: tool_call.id,
        is_error: is_error,
        trust: trust
      }
    )

    {context, new_messages, results}
  end

  defp execute_tool_call(tool, tool_call, signal, stream, parent, ref) do
    # Create update callback
    on_update = fn partial_result ->
      send(parent, {:tool_task_update, ref, partial_result})

      EventStream.push(
        stream,
        {:tool_execution_update, tool_call.id, tool_call.name, tool_call.arguments,
         partial_result}
      )

      :ok
    end

    try do
      case tool.execute.(tool_call.id, tool_call.arguments, signal, on_update) do
        {:ok, %AgentToolResult{is_error: true} = result} -> {result, true}
        {:ok, result} -> {result, false}
        {:error, reason} -> {tool_error_result(reason), true}
        %AgentToolResult{is_error: true} = result -> {result, true}
        %AgentToolResult{} = result -> {result, false}
        other -> {unexpected_tool_result(other), true}
      end
    rescue
      e ->
        {tool_exception_result(e), true}
    catch
      kind, value ->
        {tool_caught_result(kind, value), true}
    end
  end

  defp find_tool(tools, name) do
    normalized_name = normalize_tool_name(name)

    Enum.find(tools, fn tool ->
      normalized_tool_name = normalize_tool_name(tool.name)

      if normalized_name != nil and normalized_tool_name == normalized_name do
        # Emit telemetry if normalization was needed (name != tool.name after normalization)
        if tool.name != name do
          LemonCore.Telemetry.emit(
            [:lemon_agent, :tool_call, :name_normalized],
            %{system_time: System.system_time()},
            %{
              original_name: name,
              matched_tool_name: tool.name
            }
          )
        end

        true
      else
        false
      end
    end)
  end

  @doc """
  Normalizes a tool name by trimming whitespace and handling Unicode whitespace.

  Provider formatting drift can cause tool names to include accidental padding
  or non-canonical casing. This normalization ensures robust matching.

  Invalid or nonbinary names return `nil` and cannot match a tool.
  """
  @spec normalize_tool_name(term()) :: String.t() | nil
  def normalize_tool_name(name) when is_binary(name) do
    if String.valid?(name) do
      case name |> String.trim() |> normalize_unicode_whitespace() do
        "" -> nil
        normalized_name -> normalized_name
      end
    end
  end

  def normalize_tool_name(_name), do: nil

  # Replace common Unicode whitespace characters with ASCII space, then trim
  defp normalize_unicode_whitespace(name) do
    # Unicode whitespace characters to normalize
    # \s in Elixir regex covers: space, tab, newline, carriage return, form feed
    # Plus explicit Unicode: non-breaking space, en/em space, etc.
    name
    |> String.replace(@whitespace_pattern, " ")
    |> String.trim()
  end

  defp tool_error_result(reason) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: error_text(reason)}],
      details: %{error_type: :tool_error, reason: inspect(reason)}
    }
  end

  defp unexpected_tool_result(result) do
    %AgentToolResult{
      content: [
        %TextContent{type: :text, text: "Unexpected tool result: #{inspect(result)}"}
      ],
      details: %{error_type: :unexpected_tool_result, result: inspect(result)}
    }
  end

  defp tool_exception_result(exception) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: Exception.message(exception)}],
      details: %{
        error_type: :tool_exception,
        exception: exception.__struct__,
        message: Exception.message(exception)
      }
    }
  end

  defp tool_caught_result(kind, value) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: "#{kind}: #{inspect(value)}"}],
      details: %{error_type: :tool_caught, kind: kind, value: inspect(value)}
    }
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  defp prepare_tool_call(nil, tool_call), do: {:error, unknown_tool_result(tool_call)}

  defp prepare_tool_call(tool, tool_call) do
    case coerce_tool_arguments(tool.parameters, tool_call.arguments) do
      {:ok, arguments} ->
        {:ok, %{tool_call | arguments: arguments}}

      {:error, errors} ->
        {:error, invalid_arguments_result(errors)}
    end
  end

  defp coerce_tool_arguments(schema, arguments) do
    case coerce_value(%{"type" => "object"} |> Map.merge(schema || %{}), arguments) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, errors} -> {:error, List.wrap(errors)}
    end
  end

  defp coerce_value(%{"type" => types} = schema, value) when is_list(types) do
    if null_value?(value) and "null" in types do
      {:ok, nil}
    else
      types
      |> Enum.reject(&(&1 == "null"))
      |> Enum.reduce_while({:error, ["expected one of #{Enum.join(types, ", ")}"]}, fn type,
                                                                                       _acc ->
        case coerce_value(%{schema | "type" => type}, value) do
          {:ok, coerced} ->
            {:halt, {:ok, coerced}}

          {:error, _errors} ->
            {:cont, {:error, ["expected one of #{Enum.join(types, ", ")}"]}}
        end
      end)
    end
  end

  defp coerce_value(schema, value) when is_map(schema) and is_nil(value) do
    if nullable_schema?(schema) do
      {:ok, nil}
    else
      coerce_typed_value(schema, value)
    end
  end

  defp coerce_value(schema, value) when is_map(schema) and is_binary(value) do
    if nullable_schema?(schema) and String.trim(value) == "null" do
      {:ok, nil}
    else
      coerce_typed_value(schema, value)
    end
  end

  defp coerce_value(schema, value) when is_map(schema), do: coerce_typed_value(schema, value)

  defp coerce_typed_value(%{"type" => "object"} = schema, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> coerce_value(schema, decoded)
      {:error, _reason} -> {:error, ["expected object, got string"]}
    end
  end

  defp coerce_typed_value(%{"type" => "object"} = schema, value) when is_map(value) do
    required_errors =
      schema
      |> Map.get("required", [])
      |> Enum.reject(&Map.has_key?(value, &1))
      |> Enum.map(&"missing required argument #{inspect(&1)}")

    {properties, errors} =
      schema
      |> Map.get("properties", %{})
      |> Enum.reduce({value, required_errors}, fn {key, property_schema}, {acc, errors} ->
        if Map.has_key?(value, key) do
          case coerce_value(property_schema, Map.fetch!(value, key)) do
            {:ok, coerced} -> {Map.put(acc, key, coerced), errors}
            {:error, property_errors} -> {acc, errors ++ prefix_errors(key, property_errors)}
          end
        else
          {acc, errors}
        end
      end)

    if errors == [], do: {:ok, properties}, else: {:error, errors}
  end

  defp coerce_typed_value(%{"type" => "object"}, _value), do: {:error, ["expected object"]}

  defp coerce_typed_value(%{"type" => "array"} = schema, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> coerce_value(schema, decoded)
      {:ok, decoded} -> coerce_array_items(schema, [decoded])
      {:error, _reason} -> coerce_array_items(schema, [value])
    end
  end

  defp coerce_typed_value(%{"type" => "array"} = schema, value) when is_list(value) do
    coerce_array_items(schema, value)
  end

  defp coerce_typed_value(%{"type" => "array"} = schema, value),
    do: coerce_array_items(schema, [value])

  defp coerce_typed_value(%{"type" => "boolean"}, value) when is_boolean(value),
    do: {:ok, value}

  defp coerce_typed_value(%{"type" => "boolean"}, value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, ["expected boolean"]}
    end
  end

  defp coerce_typed_value(%{"type" => "boolean"}, _value), do: {:error, ["expected boolean"]}

  defp coerce_typed_value(%{"type" => "integer"}, value) when is_integer(value),
    do: {:ok, value}

  defp coerce_typed_value(%{"type" => "integer"}, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, ["expected integer"]}
    end
  end

  defp coerce_typed_value(%{"type" => "integer"}, _value), do: {:error, ["expected integer"]}

  defp coerce_typed_value(%{"type" => "number"}, value) when is_number(value),
    do: {:ok, value}

  defp coerce_typed_value(%{"type" => "number"}, value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {number, ""} -> {:ok, number}
      _ -> {:error, ["expected number"]}
    end
  end

  defp coerce_typed_value(%{"type" => "number"}, _value), do: {:error, ["expected number"]}

  defp coerce_typed_value(%{"type" => "string"}, value) when is_binary(value), do: {:ok, value}
  defp coerce_typed_value(%{"type" => "string"}, _value), do: {:error, ["expected string"]}
  defp coerce_typed_value(_schema, value), do: {:ok, value}

  defp coerce_array_items(schema, values) do
    item_schema = Map.get(schema, "items", %{})

    {coerced, errors} =
      values
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {value, index}, {items, errors} ->
        case coerce_value(item_schema, value) do
          {:ok, coerced} -> {[coerced | items], errors}
          {:error, item_errors} -> {items, errors ++ prefix_errors(index, item_errors)}
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(coerced)}, else: {:error, errors}
  end

  defp prefix_errors(prefix, errors) do
    Enum.map(List.wrap(errors), &"#{prefix}: #{&1}")
  end

  defp nullable_schema?(%{"nullable" => true}), do: true
  defp nullable_schema?(%{"type" => types}) when is_list(types), do: "null" in types
  defp nullable_schema?(_schema), do: false

  defp null_value?(nil), do: true
  defp null_value?(value) when is_binary(value), do: String.trim(value) == "null"
  defp null_value?(_value), do: false

  defp unknown_tool_result(tool_call) do
    name =
      if is_binary(tool_call.name) and String.valid?(tool_call.name),
        do: tool_call.name,
        else: inspect(tool_call.name)

    %AgentToolResult{
      content: [%TextContent{type: :text, text: "Tool #{name} not found"}],
      details: %{error_type: :unknown_tool, tool_name: tool_call.name}
    }
  end

  defp invalid_arguments_result(errors) do
    %AgentToolResult{
      content: [
        %TextContent{type: :text, text: "Invalid tool arguments: #{Enum.join(errors, "; ")}"}
      ],
      details: %{error_type: :invalid_tool_arguments, errors: errors}
    }
  end

  defp tool_start_failure_result(reason) do
    %AgentToolResult{
      content: [
        %TextContent{type: :text, text: "Tool task failed to start: #{inspect(reason)}"}
      ],
      details: %{error_type: :tool_task_start_failed, reason: inspect(reason)}
    }
  end

  defp tool_crash_result(reason) do
    %AgentToolResult{
      content: [
        %TextContent{type: :text, text: "Tool task crashed: #{inspect(reason)}"}
      ],
      details: %{error_type: :tool_task_crashed, reason: inspect(reason)}
    }
  end

  defp tool_timeout_result(timeout_ms) do
    %AgentToolResult{
      content: [
        %TextContent{type: :text, text: "Tool task timed out after #{timeout_ms}ms"}
      ],
      details: %{error_type: :tool_task_timeout, timeout_ms: timeout_ms}
    }
  end

  defp tool_aborted_result(partial, started) do
    content = if partial, do: partial.content, else: []

    notice =
      if started,
        do: "Tool execution aborted; no final result was received. Mutation outcome is unknown.",
        else: "Tool execution aborted before the call started."

    %AgentToolResult{
      content: content ++ [%TextContent{type: :text, text: notice}],
      trust: if(partial, do: partial.trust, else: :trusted),
      is_error: true,
      details: %{
        error_type: :aborted,
        cancelled: true,
        started: started,
        outcome: if(started, do: :unknown, else: :not_started),
        partial: partial != nil,
        partial_details: if(partial, do: partial.details, else: nil)
      }
    }
  end

  defp aborted_task_result(%{result: {result, false}}), do: {result, false}

  defp aborted_task_result(%{result: {%AgentToolResult{} = result, true}}) do
    details =
      case result.details do
        value when is_map(value) -> value
        nil -> %{}
        value -> %{tool_details: value}
      end
      |> Map.put(:cancelled, true)
      |> Map.put_new(:error_type, :aborted)
      |> Map.put_new(:outcome, :unknown)

    {%{result | details: details, is_error: true}, true}
  end

  defp aborted_task_result(%{partial: partial}), do: {tool_aborted_result(partial, true), true}

  defp tool_skipped_result do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool execution skipped because new user steering is queued. " <>
              "Review the new instructions before retrying this tool call."
        }
      ],
      details: %{error_type: :skipped, reason: :steering}
    }
  end

  defp resolve_max_tool_concurrency(_config, total_tool_calls) when total_tool_calls <= 0, do: 0

  defp resolve_max_tool_concurrency(
         %AgentLoopConfig{max_tool_concurrency: :infinity},
         total_tool_calls
       ) do
    total_tool_calls
  end

  defp resolve_max_tool_concurrency(
         %AgentLoopConfig{max_tool_concurrency: max_tool_concurrency},
         total_tool_calls
       )
       when is_integer(max_tool_concurrency) do
    max_tool_concurrency
    |> max(1)
    |> min(total_tool_calls)
  end

  defp resolve_max_tool_concurrency(%AgentLoopConfig{}, total_tool_calls),
    do: min(8, total_tool_calls)

  defp resolve_tool_timeout_ms(%AgentLoopConfig{tool_timeout_ms: :infinity}), do: nil

  defp resolve_tool_timeout_ms(%AgentLoopConfig{tool_timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0 do
    timeout_ms
  end

  defp resolve_tool_timeout_ms(%AgentLoopConfig{}), do: 300_000

  defp tool_timeout(%{timeout_ms: :infinity}, _default), do: nil

  defp tool_timeout(%{timeout_ms: milliseconds}, _default)
       when is_integer(milliseconds) and milliseconds > 0, do: milliseconds

  defp tool_timeout(_tool, default), do: default

  defp schedule_tool_timeout(_ref, nil), do: nil

  defp schedule_tool_timeout(ref, timeout_ms) do
    Process.send_after(self(), {:tool_task_timeout, ref}, timeout_ms)
  end

  defp cancel_tool_timeout(nil), do: :ok

  defp cancel_tool_timeout(timeout_ref) do
    Process.cancel_timer(timeout_ref)
    :ok
  end

  defp stop_aborted_tools(pending_by_ref, pending_by_mon, supervisor) do
    Enum.each(pending_by_ref, fn {_ref, pending} ->
      cancel_tool_timeout(pending.timeout_ref)
    end)

    # Give cooperative tools time to stop external work before killing their
    # BEAM worker. The run's abort signal stays set throughout this drain.
    {remaining, finished} =
      await_tool_cleanup(
        pending_by_ref,
        pending_by_mon,
        %{},
        System.monotonic_time(:millisecond) + @tool_abort_grace_ms
      )

    Enum.each(remaining, fn {_ref, pending} ->
      Task.Supervisor.terminate_child(supervisor, pending.pid)
      Process.demonitor(pending.mon_ref, [:flush])
    end)

    Map.merge(finished, remaining)
  end

  defp await_tool_cleanup(pending_by_ref, _pending_by_mon, finished, _deadline)
       when map_size(pending_by_ref) == 0, do: {pending_by_ref, finished}

  defp await_tool_cleanup(pending_by_ref, pending_by_mon, finished, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, mon_ref, :process, _pid, _reason} when is_map_key(pending_by_mon, mon_ref) ->
        ref = Map.fetch!(pending_by_mon, mon_ref)
        {pending, pending_by_ref} = Map.pop!(pending_by_ref, ref)

        await_tool_cleanup(
          pending_by_ref,
          Map.delete(pending_by_mon, mon_ref),
          Map.put(finished, ref, pending),
          deadline
        )

      {:tool_task_result, ref, _call, result, is_error} when is_map_key(pending_by_ref, ref) ->
        pending_by_ref =
          Map.update!(pending_by_ref, ref, &%{&1 | result: {result, is_error}})

        await_tool_cleanup(pending_by_ref, pending_by_mon, finished, deadline)

      {:tool_task_update, ref, partial} when is_map_key(pending_by_ref, ref) ->
        pending_by_ref = remember_partial(pending_by_ref, ref, partial)
        await_tool_cleanup(pending_by_ref, pending_by_mon, finished, deadline)
    after
      remaining_ms -> {pending_by_ref, finished}
    end
  end

  defp remember_partial(pending_by_ref, ref, %AgentToolResult{} = partial) do
    if Map.has_key?(pending_by_ref, ref),
      do: Map.update!(pending_by_ref, ref, &%{&1 | partial: partial}),
      else: pending_by_ref
  end

  defp remember_partial(pending_by_ref, _ref, _partial), do: pending_by_ref

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp has_steering_messages?(%AgentLoopConfig{has_steering_messages: nil}), do: false

  defp has_steering_messages?(%AgentLoopConfig{has_steering_messages: has_fn}) do
    has_fn.() == true
  end

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: nil}), do: []

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: get_fn}) do
    get_fn.() || []
  end

  defp normalize_trust(:untrusted), do: :untrusted
  defp normalize_trust(_), do: :trusted
end
