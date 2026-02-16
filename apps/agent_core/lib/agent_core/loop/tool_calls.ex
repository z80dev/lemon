defmodule AgentCore.Loop.ToolCalls do
  @moduledoc false

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Types.{AgentLoopConfig, AgentToolResult}

  alias Ai.Types.{
    TextContent,
    ToolResultMessage
  }

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
      execute_tool_calls_parallel(context, new_messages, tool_calls, signal, stream)

    steering_messages = get_steering_messages(config)

    {results, steering_messages, context, new_messages}
  end

  defp execute_tool_calls_parallel(context, new_messages, tool_calls, signal, stream) do
    parent = self()

    {pending_by_ref, pending_by_mon} =
      Enum.reduce(tool_calls, {%{}, %{}}, fn tool_call, {by_ref, by_mon} ->
        tool = find_tool(context.tools, tool_call.name)

        EventStream.push(
          stream,
          {:tool_execution_start, tool_call.id, tool_call.name, tool_call.arguments}
        )

        ref = make_ref()

        # Emit telemetry for tool task start
        LemonCore.Telemetry.emit(
          [:agent_core, :tool_task, :start],
          %{system_time: System.system_time()},
          %{tool_name: tool_call.name, tool_call_id: tool_call.id}
        )

        {:ok, pid} =
          Task.Supervisor.start_child(AgentCore.ToolTaskSupervisor, fn ->
            {result, is_error} = execute_tool_call(tool, tool_call, signal, stream)
            send(parent, {:tool_task_result, ref, tool_call, result, is_error})
          end)

        mon_ref = Process.monitor(pid)

        {
          Map.put(by_ref, ref, %{tool_call: tool_call, mon_ref: mon_ref, pid: pid}),
          Map.put(by_mon, mon_ref, ref)
        }
      end)

    collect_parallel_tool_results(
      context,
      new_messages,
      pending_by_ref,
      pending_by_mon,
      [],
      stream,
      signal
    )
  end

  defp collect_parallel_tool_results(
         context,
         new_messages,
         pending_by_ref,
         pending_by_mon,
         results,
         stream,
         signal
       ) do
    if map_size(pending_by_ref) == 0 do
      {Enum.reverse(results), context, new_messages}
    else
      # Check for abort before waiting
      if aborted?(signal) do
        # Terminate all pending tool tasks on abort
        Enum.each(pending_by_ref, fn {_ref, %{mon_ref: mon_ref, pid: pid, tool_call: tool_call}} ->
          Task.Supervisor.terminate_child(AgentCore.ToolTaskSupervisor, pid)
          Process.demonitor(mon_ref, [:flush])

          LemonCore.Telemetry.emit(
            [:agent_core, :tool_task, :error],
            %{system_time: System.system_time()},
            %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: :aborted}
          )
        end)

        # Return aborted results for remaining tool calls
        {aborted_results, context, new_messages} =
          Enum.reduce(pending_by_ref, {results, context, new_messages}, fn {_ref,
                                                                            %{
                                                                              tool_call: tool_call
                                                                            }},
                                                                           {acc_results, acc_ctx,
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

        {Enum.reverse(aborted_results), context, new_messages}
      else
        receive do
          {:tool_task_result, ref, tool_call, result, is_error} ->
            {pending_by_ref, pending_by_mon} =
              drop_pending_task(pending_by_ref, pending_by_mon, ref)

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

            collect_parallel_tool_results(
              context,
              new_messages,
              pending_by_ref,
              pending_by_mon,
              results,
              stream,
              signal
            )

          {:DOWN, mon_ref, :process, _pid, reason} ->
            case Map.get(pending_by_mon, mon_ref) do
              nil ->
                collect_parallel_tool_results(
                  context,
                  new_messages,
                  pending_by_ref,
                  pending_by_mon,
                  results,
                  stream,
                  signal
                )

              ref ->
                %{tool_call: tool_call} = Map.fetch!(pending_by_ref, ref)

                {pending_by_ref, pending_by_mon} =
                  drop_pending_task(pending_by_ref, pending_by_mon, ref)

                # Emit telemetry for tool task error (crash)
                LemonCore.Telemetry.emit(
                  [:agent_core, :tool_task, :error],
                  %{system_time: System.system_time()},
                  %{tool_name: tool_call.name, tool_call_id: tool_call.id, reason: reason}
                )

                {context, new_messages, results} =
                  emit_tool_result(
                    tool_call,
                    error_to_result("Tool task crashed: #{inspect(reason)}"),
                    true,
                    context,
                    new_messages,
                    results,
                    stream
                  )

                collect_parallel_tool_results(
                  context,
                  new_messages,
                  pending_by_ref,
                  pending_by_mon,
                  results,
                  stream,
                  signal
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
              results,
              stream,
              signal
            )
        end
      end
    end
  end

  defp drop_pending_task(pending_by_ref, pending_by_mon, ref) do
    case Map.pop(pending_by_ref, ref) do
      {nil, pending_by_ref} ->
        {pending_by_ref, pending_by_mon}

      {%{mon_ref: mon_ref}, pending_by_ref} ->
        Process.demonitor(mon_ref, [:flush])
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

  defp execute_tool_call(nil, tool_call, _signal, _stream) do
    error_result = %AgentToolResult{
      content: [%TextContent{type: :text, text: "Tool #{tool_call.name} not found"}],
      details: nil
    }

    {error_result, true}
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
        {:error, reason} -> {error_to_result(reason), true}
        %AgentToolResult{} = result -> {result, false}
        other -> {error_to_result("Unexpected tool result: #{inspect(other)}"), true}
      end
    rescue
      e ->
        {error_to_result(Exception.message(e)), true}
    catch
      kind, value ->
        {error_to_result("#{kind}: #{inspect(value)}"), true}
    end
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn tool -> tool.name == name end)
  end

  defp error_to_result(reason) when is_binary(reason) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: reason}],
      details: nil
    }
  end

  defp error_to_result(reason) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: inspect(reason)}],
      details: nil
    }
  end

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: nil}), do: []

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: get_fn}) do
    get_fn.() || []
  end

  defp normalize_trust(:untrusted), do: :untrusted
  defp normalize_trust(_), do: :trusted
end
