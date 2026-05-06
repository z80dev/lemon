defmodule AgentCore.Loop.ToolCalls do
  @moduledoc false

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Types.{AgentLoopConfig, AgentToolResult}

  alias Ai.Types.{
    TextContent,
    ToolResultMessage
  }

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
          AgentCore.Types.AgentContext.t(),
          [AgentCore.Types.agent_message()],
          [Ai.Types.ToolCall.t()],
          AgentLoopConfig.t(),
          reference() | nil,
          EventStream.t()
        ) ::
          {[ToolResultMessage.t()], [AgentCore.Types.agent_message()],
           AgentCore.Types.AgentContext.t(), [AgentCore.Types.agent_message()]}
  def execute_and_collect_tools(context, new_messages, tool_calls, config, signal, stream) do
    {results, steering_messages, context, new_messages} =
      execute_tool_calls(context, new_messages, tool_calls, config, signal, stream)

    {results, steering_messages, context, new_messages}
  end

  defp execute_tool_calls(context, new_messages, tool_calls, config, signal, stream) do
    {results, context, new_messages} =
      execute_tool_calls_parallel(context, new_messages, tool_calls, config, signal, stream)

    steering_messages = get_steering_messages(config)

    {results, steering_messages, context, new_messages}
  end

  defp execute_tool_calls_parallel(context, new_messages, tool_calls, config, signal, stream) do
    max_concurrency = resolve_max_tool_concurrency(config, length(tool_calls))
    tool_timeout_ms = resolve_tool_timeout_ms(config)
    tool_task_supervisor = config.tool_task_supervisor || AgentCore.ToolTaskSupervisor
    tool_call_order = tool_call_order(tool_calls)
    base_context_message_count = length(context.messages)
    base_new_message_count = length(new_messages)

    {pending_by_ref, pending_by_mon, remaining_tool_calls, start_failures} =
      start_tool_tasks(
        context.tools,
        tool_calls,
        %{},
        %{},
        max_concurrency,
        tool_timeout_ms,
        signal,
        stream,
        tool_task_supervisor
      )

    {context, new_messages, results} =
      emit_start_failures(start_failures, context, new_messages, [], stream)

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
      base_new_message_count
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
         base_new_message_count
       ) do
    if map_size(pending_by_ref) == 0 and remaining_tool_calls == [] do
      finish_tool_results(
        results,
        context,
        new_messages,
        tool_call_order,
        base_context_message_count,
        base_new_message_count
      )
    else
      # Check for abort before waiting
      if aborted?(signal) do
        # Terminate all pending tool tasks on abort
        Enum.each(pending_by_ref, fn {_ref, %{mon_ref: mon_ref, pid: pid, tool_call: tool_call}} ->
          Task.Supervisor.terminate_child(tool_task_supervisor, pid)
          Process.demonitor(mon_ref, [:flush])

          LemonCore.Telemetry.emit(
            [:agent_core, :tool_task, :error],
            %{system_time: System.system_time()},
            %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: :aborted}
          )
        end)

        pending_tool_calls =
          pending_by_ref
          |> Map.values()
          |> Enum.map(& &1.tool_call)

        all_aborted_tool_calls = pending_tool_calls ++ remaining_tool_calls

        Enum.each(remaining_tool_calls, fn tool_call ->
          LemonCore.Telemetry.emit(
            [:agent_core, :tool_task, :error],
            %{system_time: System.system_time()},
            %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: :aborted}
          )
        end)

        {aborted_results, context, new_messages} =
          Enum.reduce(all_aborted_tool_calls, {results, context, new_messages}, fn tool_call,
                                                                                   {acc_results,
                                                                                    acc_ctx,
                                                                                    acc_msgs} ->
            aborted_result = %AgentToolResult{
              content: [%TextContent{type: :text, text: "Tool execution aborted"}],
              details: %{error_type: :aborted}
            }

            {acc_ctx, acc_msgs, acc_results} =
              emit_tool_result(
                tool_call,
                aborted_result,
                true,
                acc_ctx,
                acc_msgs,
                acc_results,
                stream
              )

            {acc_results, acc_ctx, acc_msgs}
          end)

        finish_tool_results(
          aborted_results,
          context,
          new_messages,
          tool_call_order,
          base_context_message_count,
          base_new_message_count
        )
      else
        receive do
          {:tool_task_result, ref, tool_call, result, is_error} ->
            {pending_by_ref, pending_by_mon} =
              drop_pending_task(pending_by_ref, pending_by_mon, ref)

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
                tool_task_supervisor
              )

            # Emit telemetry for tool task end
            LemonCore.Telemetry.emit(
              [:agent_core, :tool_task, :end],
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

            {context, new_messages, results} =
              emit_start_failures(start_failures, context, new_messages, results, stream)

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
              base_new_message_count
            )

          {:DOWN, mon_ref, :process, _pid, reason} ->
            case Map.get(pending_by_mon, mon_ref) do
              nil ->
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
                  base_new_message_count
                )

              ref ->
                %{tool_call: tool_call} = Map.fetch!(pending_by_ref, ref)

                {pending_by_ref, pending_by_mon} =
                  drop_pending_task(pending_by_ref, pending_by_mon, ref)

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
                    tool_task_supervisor
                  )

                # Emit telemetry for tool task error (crash)
                LemonCore.Telemetry.emit(
                  [:agent_core, :tool_task, :error],
                  %{system_time: System.system_time()},
                  %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: reason}
                )

                {context, new_messages, results} =
                  emit_tool_result(
                    tool_call,
                    tool_crash_result(reason),
                    true,
                    context,
                    new_messages,
                    results,
                    stream
                  )

                {context, new_messages, results} =
                  emit_start_failures(start_failures, context, new_messages, results, stream)

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
                  base_new_message_count
                )
            end

          {:tool_task_timeout, ref} ->
            case Map.get(pending_by_ref, ref) do
              nil ->
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
                  base_new_message_count
                )

              %{tool_call: tool_call, mon_ref: mon_ref, pid: pid} ->
                Task.Supervisor.terminate_child(tool_task_supervisor, pid)
                Process.demonitor(mon_ref, [:flush])

                {pending_by_ref, pending_by_mon} =
                  drop_pending_task(pending_by_ref, pending_by_mon, ref)

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
                    tool_task_supervisor
                  )

                LemonCore.Telemetry.emit(
                  [:agent_core, :tool_task, :error],
                  %{system_time: System.system_time()},
                  %{
                    tool_name: tool_call.name,
                    tool_call_id: tool_call.id,
                    reason: :timeout
                  }
                )

                {context, new_messages, results} =
                  emit_tool_result(
                    tool_call,
                    tool_timeout_result(tool_timeout_ms),
                    true,
                    context,
                    new_messages,
                    results,
                    stream
                  )

                {context, new_messages, results} =
                  emit_start_failures(start_failures, context, new_messages, results, stream)

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
                  base_new_message_count
                )
            end
        after
          100 ->
            # Periodically check for abort
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
              base_new_message_count
            )
        end
      end
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
         _tool_task_supervisor
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
         tool_task_supervisor
       ) do
    if aborted?(signal) do
      {pending_by_ref, pending_by_mon, remaining_tool_calls, []}
    else
      parent = self()

      {by_ref, by_mon, remaining, start_failures} =
        Enum.reduce_while(
          1..available_slots,
          {pending_by_ref, pending_by_mon, remaining_tool_calls, []},
          fn _, {by_ref, by_mon, remaining, start_failures} ->
            case remaining do
              [] ->
                {:halt, {by_ref, by_mon, remaining, start_failures}}

              [tool_call | rest] ->
                tool = find_tool(tools, tool_call.name)

                EventStream.push(
                  stream,
                  {:tool_execution_start, tool_call.id, tool_call.name, tool_call.arguments}
                )

                ref = make_ref()

                LemonCore.Telemetry.emit(
                  [:agent_core, :tool_task, :start],
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
                        timeout_ref = schedule_tool_timeout(ref, tool_timeout_ms)

                        {:cont,
                         {
                           Map.put(by_ref, ref, %{
                             tool_call: prepared_tool_call,
                             mon_ref: mon_ref,
                             pid: pid,
                             timeout_ref: timeout_ref
                           }),
                           Map.put(by_mon, mon_ref, ref),
                           rest,
                           start_failures
                         }}

                      {:error, reason} ->
                        LemonCore.Telemetry.emit(
                          [:agent_core, :tool_task, :error],
                          %{system_time: System.system_time()},
                          %{
                            tool_name: tool_call.name,
                            tool_call_id: tool_call.id,
                            reason: {:start_failed, reason}
                          }
                        )

                        failure = {tool_call, tool_start_failure_result(reason)}
                        {:cont, {by_ref, by_mon, rest, [failure | start_failures]}}
                    end

                  {:error, result} ->
                    LemonCore.Telemetry.emit(
                      [:agent_core, :tool_task, :error],
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
    try do
      Task.Supervisor.start_child(tool_task_supervisor, fn ->
        {result, is_error} = execute_tool_call(tool, tool_call, signal, stream)
        send(parent, {:tool_task_result, ref, tool_call, result, is_error})
      end)
    catch
      :exit, reason -> {:error, reason}
    else
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_start_result, other}}
    end
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
      [:agent_core, :tool_result, :emit],
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

  defp execute_tool_call(tool, tool_call, signal, stream) do
    execute_single_tool(tool, tool_call, signal, stream)
  end

  defp execute_single_tool(tool, tool_call, signal, stream) do
    # Create update callback
    on_update = fn partial_result ->
      EventStream.push(
        stream,
        {:tool_execution_update, tool_call.id, tool_call.name, tool_call.arguments,
         partial_result}
      )

      :ok
    end

    try do
      case tool.execute.(tool_call.id, tool_call.arguments, signal, on_update) do
        {:ok, result} -> {result, false}
        {:error, reason} -> {tool_error_result(reason), true}
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

      if normalized_tool_name == normalized_name do
        # Emit telemetry if normalization was needed (name != tool.name after normalization)
        if tool.name != name do
          LemonCore.Telemetry.emit(
            [:agent_core, :tool_call, :name_normalized],
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
  """
  @spec normalize_tool_name(String.t()) :: String.t()
  def normalize_tool_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> normalize_unicode_whitespace()
  end

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

  defp coerce_value(%{"type" => "object"} = schema, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> coerce_value(schema, decoded)
      {:error, _reason} -> {:error, ["expected object, got string"]}
    end
  end

  defp coerce_value(%{"type" => "object"} = schema, value) when is_map(value) do
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

  defp coerce_value(%{"type" => "object"}, _value), do: {:error, ["expected object"]}

  defp coerce_value(%{"type" => "array"} = schema, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> coerce_value(schema, decoded)
      {:ok, decoded} -> coerce_array_items(schema, [decoded])
      {:error, _reason} -> coerce_array_items(schema, [value])
    end
  end

  defp coerce_value(%{"type" => "array"} = schema, value) when is_list(value) do
    coerce_array_items(schema, value)
  end

  defp coerce_value(%{"type" => "array"} = schema, value), do: coerce_array_items(schema, [value])

  defp coerce_value(%{"type" => "boolean"}, value) when is_boolean(value), do: {:ok, value}

  defp coerce_value(%{"type" => "boolean"}, value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, ["expected boolean"]}
    end
  end

  defp coerce_value(%{"type" => "boolean"}, _value), do: {:error, ["expected boolean"]}

  defp coerce_value(%{"type" => "integer"}, value) when is_integer(value), do: {:ok, value}

  defp coerce_value(%{"type" => "integer"}, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, ["expected integer"]}
    end
  end

  defp coerce_value(%{"type" => "integer"}, _value), do: {:error, ["expected integer"]}

  defp coerce_value(%{"type" => "number"}, value) when is_number(value), do: {:ok, value}

  defp coerce_value(%{"type" => "number"}, value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {number, ""} -> {:ok, number}
      _ -> {:error, ["expected number"]}
    end
  end

  defp coerce_value(%{"type" => "number"}, _value), do: {:error, ["expected number"]}

  defp coerce_value(%{"type" => "string"}, value) when is_binary(value), do: {:ok, value}
  defp coerce_value(%{"type" => "string"}, _value), do: {:error, ["expected string"]}
  defp coerce_value(_schema, value), do: {:ok, value}

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

  defp unknown_tool_result(tool_call) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: "Tool #{tool_call.name} not found"}],
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

  defp resolve_max_tool_concurrency(%AgentLoopConfig{}, total_tool_calls), do: total_tool_calls

  defp resolve_tool_timeout_ms(%AgentLoopConfig{tool_timeout_ms: :infinity}), do: nil

  defp resolve_tool_timeout_ms(%AgentLoopConfig{tool_timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0 do
    timeout_ms
  end

  defp resolve_tool_timeout_ms(%AgentLoopConfig{}), do: nil

  defp schedule_tool_timeout(_ref, nil), do: nil

  defp schedule_tool_timeout(ref, timeout_ms) do
    Process.send_after(self(), {:tool_task_timeout, ref}, timeout_ms)
  end

  defp cancel_tool_timeout(nil), do: :ok

  defp cancel_tool_timeout(timeout_ref) do
    Process.cancel_timer(timeout_ref)
    :ok
  end

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: nil}), do: []

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: get_fn}) do
    get_fn.() || []
  end

  defp normalize_trust(:untrusted), do: :untrusted
  defp normalize_trust(_), do: :trusted
end
