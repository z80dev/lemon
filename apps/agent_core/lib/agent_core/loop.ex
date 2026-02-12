defmodule AgentCore.Loop do
  @moduledoc """
  Stateless agent loop functions for conversation management.

  This module implements the core agent loop logic that orchestrates:
  - Streaming LLM responses
  - Tool call execution
  - Steering message injection
  - Follow-up message handling

  The loop works with `AgentCore.EventStream` to emit events for UI clients
  and returns the final list of new messages created during the run.

  ## Entry Points

  - `agent_loop/5` - Start a new agent loop with prompt messages
  - `agent_loop_continue/4` - Continue from an existing context

  ## Event Flow

  The loop emits events in a specific sequence:

      {:agent_start}
      {:turn_start}
      {:message_start, prompt}
      {:message_end, prompt}
      {:message_start, assistant_msg}
      {:message_update, assistant_msg, event}
      ...
      {:message_end, assistant_msg}
      {:tool_execution_start, id, name, args}
      {:tool_execution_update, id, name, args, partial}
      {:tool_execution_end, id, name, result, is_error}
      {:message_start, tool_result}
      {:message_end, tool_result}
      {:turn_end, assistant_msg, tool_results}
      ... (more turns if tool calls or steering)
      {:agent_end, new_messages}

  ## Abort Handling

  The `signal` parameter is a reference that can be used for abort handling.
  Check for abort by monitoring the signal or using Process messages.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}

  alias Ai.Types.{
    AssistantMessage,
    ToolResultMessage,
    TextContent,
    ToolCall,
    Context,
    Tool,
    Usage,
    Cost
  }

  @loop_abort_signal_pd_key :agent_abort_signal

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start an agent loop with new prompt messages.

  Creates a new `EventStream`, emits lifecycle events for the prompts,
  and starts the main loop in an async task.

  ## Parameters

  - `prompts` - List of agent messages to add to context as the prompt
  - `context` - The current agent context (system prompt, messages, tools)
  - `config` - Agent loop configuration (model, convert_to_llm, etc.)
  - `signal` - Optional abort signal reference for cancellation
  - `stream_fn` - Optional custom stream function (defaults to `Ai.stream/3`)

  ## Returns

  An `EventStream` that will emit agent events and complete with
  `{:ok, new_messages}` where `new_messages` contains only the messages
  created during this run (not the original context messages).

  ## Examples

      context = AgentContext.new(system_prompt: "You are helpful")
      config = %AgentLoopConfig{model: model, convert_to_llm: &convert/1}
      prompt = %Ai.Types.UserMessage{content: "Hello", timestamp: now()}

      stream = AgentCore.Loop.agent_loop([prompt], context, config, nil, nil)

      for event <- EventStream.events(stream) do
        IO.inspect(event)
      end
  """
  @spec agent_loop(
          [AgentCore.Types.agent_message()],
          AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil
        ) :: EventStream.t()
  def agent_loop(prompts, context, config, signal, stream_fn) do
    agent_loop(prompts, context, config, signal, stream_fn, nil)
  end

  @spec agent_loop(
          [AgentCore.Types.agent_message()],
          AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil,
          pid() | nil
        ) :: EventStream.t()
  def agent_loop(prompts, context, config, signal, stream_fn, owner) do
    {:ok, stream} =
      if owner do
        EventStream.start_link(owner: owner, timeout: :infinity)
      else
        EventStream.start_link(timeout: :infinity)
      end

    # Run the loop in a supervised task
    case Task.Supervisor.start_child(AgentCore.LoopTaskSupervisor, fn ->
           try do
             run_agent_loop(prompts, context, config, signal, stream_fn, stream)
           rescue
             e ->
               EventStream.error(stream, {:exception, Exception.message(e)}, nil)
           catch
             kind, value ->
               EventStream.error(stream, {kind, value}, nil)
           end
         end) do
      {:ok, pid} ->
        EventStream.attach_task(stream, pid)

      {:ok, pid, _info} ->
        EventStream.attach_task(stream, pid)

      {:error, reason} ->
        EventStream.error(stream, {:task_start_failed, reason}, nil)
    end

    stream
  end

  @doc """
  Start an agent loop and return an Enumerable of events.

  This is a convenience wrapper around `agent_loop/5` that returns the
  EventStream's events directly as an Enumerable, suitable for use with
  `Enum` or `Stream` functions.

  ## Parameters

  - `prompts` - List of agent messages to add to context as the prompt
  - `context` - The current agent context
  - `config` - Agent loop configuration
  - `stream_fn` - Optional custom stream function

  ## Returns

  An Enumerable of agent events.
  """
  @spec stream(
          [AgentCore.Types.agent_message()],
          AgentContext.t(),
          AgentLoopConfig.t(),
          AgentLoopConfig.stream_fn() | nil
        ) :: Enumerable.t()
  def stream(prompts, context, config, stream_fn \\ nil) do
    event_stream = agent_loop(prompts, context, config, nil, stream_fn)
    EventStream.events(event_stream)
  end

  @doc """
  Continue an agent loop from an existing context without adding new messages.

  Used for retries or continuing after tool results have been added to context.
  The context must not be empty and the last message must not be an assistant message.

  ## Parameters

  - `context` - The agent context to continue from
  - `config` - Agent loop configuration
  - `signal` - Optional abort signal reference
  - `stream_fn` - Optional custom stream function

  ## Raises

  - `ArgumentError` if context has no messages
  - `ArgumentError` if last message is an assistant message

  ## Examples

      # After adding tool results to context
      stream = AgentCore.Loop.agent_loop_continue(context, config, nil, nil)
  """
  @spec agent_loop_continue(
          AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil
        ) :: EventStream.t()
  def agent_loop_continue(context, config, signal, stream_fn) do
    agent_loop_continue(context, config, signal, stream_fn, nil)
  end

  @spec agent_loop_continue(
          AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil,
          pid() | nil
        ) :: EventStream.t()
  def agent_loop_continue(context, config, signal, stream_fn, owner) do
    # Validate context
    if context.messages == [] do
      raise ArgumentError, "Cannot continue: no messages in context"
    end

    last_message = List.last(context.messages)

    if is_assistant_message?(last_message) do
      raise ArgumentError, "Cannot continue from message role: assistant"
    end

    {:ok, stream} =
      if owner do
        EventStream.start_link(owner: owner, timeout: :infinity)
      else
        EventStream.start_link(timeout: :infinity)
      end

    case Task.Supervisor.start_child(AgentCore.LoopTaskSupervisor, fn ->
           try do
             run_continue_loop(context, config, signal, stream_fn, stream)
           rescue
             e ->
               EventStream.error(stream, {:exception, Exception.message(e)}, nil)
           catch
             kind, value ->
               EventStream.error(stream, {kind, value}, nil)
           end
         end) do
      {:ok, pid} ->
        EventStream.attach_task(stream, pid)

      {:ok, pid, _info} ->
        EventStream.attach_task(stream, pid)

      {:error, reason} ->
        EventStream.error(stream, {:task_start_failed, reason}, nil)
    end

    stream
  end

  @doc """
  Continue an agent loop and return an Enumerable of events.

  This is a convenience wrapper around `agent_loop_continue/4` that returns
  the EventStream's events directly as an Enumerable.

  ## Parameters

  - `context` - The agent context to continue from
  - `config` - Agent loop configuration
  - `stream_fn` - Optional custom stream function

  ## Returns

  An Enumerable of agent events.
  """
  @spec stream_continue(
          AgentContext.t(),
          AgentLoopConfig.t(),
          AgentLoopConfig.stream_fn() | nil
        ) :: Enumerable.t()
  def stream_continue(context, config, stream_fn \\ nil) do
    event_stream = agent_loop_continue(context, config, nil, stream_fn)
    EventStream.events(event_stream)
  end

  # ============================================================================
  # Private: Entry Point Implementations
  # ============================================================================

  defp run_agent_loop(prompts, context, config, signal, stream_fn, stream) do
    # Store start time for duration calculation in telemetry
    Process.put(:agent_loop_start_time, System.monotonic_time())
    maybe_put_loop_abort_signal(signal)

    LemonCore.Telemetry.emit(
      [:agent_core, :loop, :start],
      %{system_time: System.system_time()},
      %{
        prompt_count: length(prompts),
        message_count: length(context.messages),
        tool_count: length(context.tools),
        model: get_model_id(config)
      }
    )

    new_messages = prompts

    current_context = %{
      context
      | messages: context.messages ++ prompts
    }

    # Emit initial events
    EventStream.push(stream, {:agent_start})
    EventStream.push(stream, {:turn_start})

    # Emit message events for each prompt
    for prompt <- prompts do
      EventStream.push(stream, {:message_start, prompt})
      EventStream.push(stream, {:message_end, prompt})
    end

    # Run the main loop
    run_loop(current_context, new_messages, config, signal, stream_fn, stream)
  end

  defp run_continue_loop(context, config, signal, stream_fn, stream) do
    # Store start time for duration calculation in telemetry
    Process.put(:agent_loop_start_time, System.monotonic_time())
    maybe_put_loop_abort_signal(signal)

    LemonCore.Telemetry.emit(
      [:agent_core, :loop, :start],
      %{system_time: System.system_time()},
      %{
        prompt_count: 0,
        message_count: length(context.messages),
        tool_count: length(context.tools),
        model: get_model_id(config)
      }
    )

    new_messages = []
    current_context = context

    EventStream.push(stream, {:agent_start})
    EventStream.push(stream, {:turn_start})

    run_loop(current_context, new_messages, config, signal, stream_fn, stream)
  end

  # ============================================================================
  # Private: Main Loop
  # ============================================================================

  defp run_loop(context, new_messages, config, signal, stream_fn, stream) do
    # Check for steering messages at start (user may have typed while waiting)
    pending_messages = get_steering_messages(config) || []

    do_run_loop(context, new_messages, config, signal, stream_fn, stream, pending_messages, true)
  end

  # Main loop with outer/inner loop structure
  defp do_run_loop(
         context,
         new_messages,
         config,
         signal,
         stream_fn,
         stream,
         pending_messages,
         first_turn
       ) do
    # Inner loop: process tool calls and steering messages
    {context, new_messages, _pending_out, continue_outer} =
      do_inner_loop(
        context,
        new_messages,
        config,
        signal,
        stream_fn,
        stream,
        pending_messages,
        first_turn,
        _has_more_tool_calls = true,
        _steering_after_tools = nil
      )

    if continue_outer do
      # Check for follow-up messages
      follow_up_messages = get_follow_up_messages(config) || []

      if follow_up_messages != [] do
        # Set as pending so inner loop processes them
        do_run_loop(
          context,
          new_messages,
          config,
          signal,
          stream_fn,
          stream,
          follow_up_messages,
          false
        )
      else
        # No more messages, exit
        emit_loop_end_telemetry(new_messages, config, :completed)
        EventStream.push(stream, {:agent_end, new_messages})
        EventStream.complete(stream, new_messages)
      end
    else
      # Inner loop signaled early exit (error/abort)
      emit_loop_end_telemetry(new_messages, config, :early_exit)
      :ok
    end
  end

  # Inner loop: process tool calls and steering messages
  defp do_inner_loop(
         context,
         new_messages,
         _config,
         _signal,
         _stream_fn,
         _stream,
         pending_messages,
         _first_turn,
         false = _has_more_tool_calls,
         _steering_after_tools
       )
       when pending_messages == [] do
    # Exit condition: no more tool calls and no pending messages
    {context, new_messages, pending_messages, true}
  end

  defp do_inner_loop(
         context,
         new_messages,
         config,
         signal,
         stream_fn,
         stream,
         pending_messages,
         first_turn,
         _has_more_tool_calls,
         _steering_after_tools
       ) do
    # Emit turn_start if not first turn
    if not first_turn do
      EventStream.push(stream, {:turn_start})
    end

    # Process pending messages (inject before next assistant response)
    {context, new_messages, _cleared_pending} =
      process_pending_messages(context, new_messages, pending_messages, stream)

    # Stream assistant response
    case stream_assistant_response(context, config, signal, stream_fn, stream) do
      {:ok, message, context} ->
        new_messages = new_messages ++ [message]

        case message.stop_reason do
          :aborted ->
            EventStream.push(stream, {:turn_end, message, []})
            EventStream.cancel(stream, :assistant_aborted)
            {context, new_messages, [], false}

          :error ->
            EventStream.push(stream, {:turn_end, message, []})

            reason =
              case message.error_message do
                msg when is_binary(msg) and byte_size(msg) > 0 -> {:assistant_error, msg}
                _ -> :assistant_error
              end

            EventStream.error(stream, reason, %{new_messages: new_messages})
            {context, new_messages, [], false}

          _ ->
            # Check for tool calls
            tool_calls = get_tool_calls(message)
            has_more_tool_calls = tool_calls != []

            {tool_results, steering_after_tools, context, new_messages} =
              if has_more_tool_calls do
                execute_and_collect_tools(
                  context,
                  new_messages,
                  tool_calls,
                  config,
                  signal,
                  stream
                )
              else
                {[], nil, context, new_messages}
              end

            EventStream.push(stream, {:turn_end, message, tool_results})

            # Get steering messages after turn completes
            pending_messages =
              if steering_after_tools && steering_after_tools != [] do
                steering_after_tools
              else
                get_steering_messages(config) || []
              end

            # Continue inner loop
            do_inner_loop(
              context,
              new_messages,
              config,
              signal,
              stream_fn,
              stream,
              pending_messages,
              false,
              has_more_tool_calls,
              nil
            )
        end

      {:error, reason} ->
        EventStream.error(stream, reason, new_messages)
        {context, new_messages, [], false}
    end
  end

  defp process_pending_messages(context, new_messages, [], _stream) do
    {context, new_messages, []}
  end

  defp process_pending_messages(context, new_messages, pending_messages, stream) do
    for message <- pending_messages do
      EventStream.push(stream, {:message_start, message})
      EventStream.push(stream, {:message_end, message})
    end

    context = %{context | messages: context.messages ++ pending_messages}
    new_messages = new_messages ++ pending_messages

    {context, new_messages, []}
  end

  # ============================================================================
  # Private: Stream Assistant Response
  # ============================================================================

  defp stream_assistant_response(context, config, signal, stream_fn, stream) do
    if aborted?(signal) do
      abort_message = build_error_message(config, :aborted, "Request was aborted")
      {abort_message, context} = finalize_message(abort_message, context, false, stream)
      {:ok, abort_message, context}
    else
      with {:ok, messages} <- transform_messages(context, config, signal),
           {:ok, llm_messages} <- convert_messages(config, messages) do
        # Build LLM context
        llm_context = %Context{
          system_prompt: context.system_prompt,
          messages: llm_messages,
          tools: convert_tools_to_llm(context.tools)
        }

        # Resolve stream function
        stream_function = stream_fn || config.stream_fn || (&default_stream_fn/3)

        # Resolve API key (important for expiring tokens)
        api_key =
          case config.get_api_key do
            nil ->
              config.stream_options.api_key

            get_key_fn ->
              provider = config.model.provider

              get_key_fn.(provider) ||
                if(is_atom(provider), do: get_key_fn.(Atom.to_string(provider))) ||
                config.stream_options.api_key
          end

        options = %{config.stream_options | api_key: api_key}

        # Call the stream function (support {:ok, stream} or direct stream pid)
        case stream_function.(config.model, llm_context, options) do
          {:ok, response_stream} ->
            process_stream_events(context, response_stream, stream, config, signal)

          {:error, reason} ->
            {:error, reason}

          response_stream when is_pid(response_stream) ->
            process_stream_events(context, response_stream, stream, config, signal)

          other ->
            {:error, {:invalid_stream, other}}
        end
      else
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp process_stream_events(context, response_stream, stream, config, signal) do
    # Accumulate the partial message
    result =
      Enum.reduce_while(
        ai_events(response_stream),
        {nil, context, false},
        fn event, {partial, ctx, added} ->
          if aborted?(signal) do
            Ai.EventStream.cancel(response_stream, :aborted)

            {final_message, final_ctx} =
              finalize_canceled_message(partial, ctx, added, stream, config, :aborted)

            {:halt, {:done, final_message, final_ctx}}
          else
            case process_stream_event(event, partial, ctx, added, stream, config) do
              {:continue, new_partial, new_ctx, new_added} ->
                {:cont, {new_partial, new_ctx, new_added}}

              {:done, final_message, final_ctx} ->
                {:halt, {:done, final_message, final_ctx}}
            end
          end
        end
      )

    case result do
      {:done, final_message, ctx} ->
        {:ok, final_message, ctx}

      {partial, ctx, added} when partial != nil ->
        # Stream ended without done/error event - finalize with partial
        {final_message, final_ctx} = finalize_message(partial, ctx, added, stream)
        {:ok, final_message, final_ctx}

      _ ->
        {:error, :no_response}
    end
  end

  defp process_stream_event({:start, partial}, _partial, context, _added, stream, _config) do
    # Add partial to context
    context = %{context | messages: context.messages ++ [partial]}
    EventStream.push(stream, {:message_start, copy_message(partial)})
    {:continue, partial, context, true}
  end

  defp process_stream_event(event, partial, context, added, stream, _config)
       when elem(event, 0) in [
              :text_start,
              :text_delta,
              :text_end,
              :thinking_start,
              :thinking_delta,
              :thinking_end,
              :tool_call_start,
              :tool_call_delta,
              :tool_call_end
            ] do
    if partial != nil do
      # Get the updated partial from the event
      updated_partial = get_partial_from_event(event)

      # Update context with new partial
      context = update_last_message(context, updated_partial)

      EventStream.push(stream, {:message_update, copy_message(updated_partial), event})
      {:continue, updated_partial, context, added}
    else
      {:continue, partial, context, added}
    end
  end

  defp process_stream_event(
         {:done, _reason, final_message},
         _partial,
         context,
         added,
         stream,
         _config
       ) do
    {final_message, context} = finalize_message(final_message, context, added, stream)
    {:done, final_message, context}
  end

  defp process_stream_event(
         {:error, _reason, final_message},
         _partial,
         context,
         added,
         stream,
         _config
       ) do
    {final_message, context} = finalize_message(final_message, context, added, stream)
    {:done, final_message, context}
  end

  defp process_stream_event({:canceled, reason}, partial, context, added, stream, config) do
    {final_message, context} =
      finalize_canceled_message(partial, context, added, stream, config, reason)

    {:done, final_message, context}
  end

  defp process_stream_event(_event, partial, context, added, _stream, _config) do
    {:continue, partial, context, added}
  end

  # Extract the partial message from stream events
  defp get_partial_from_event({_type, _idx, partial}) when is_struct(partial, AssistantMessage),
    do: partial

  defp get_partial_from_event({_type, _idx, _delta, partial})
       when is_struct(partial, AssistantMessage),
       do: partial

  defp get_partial_from_event({_type, _idx, _tool_call, partial})
       when is_struct(partial, AssistantMessage),
       do: partial

  defp get_partial_from_event(_), do: nil

  # ============================================================================
  # Private: Tool Execution
  # ============================================================================

  defp execute_and_collect_tools(context, new_messages, tool_calls, config, signal, stream) do
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

    tool_result_message = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      content: result.content,
      details: result.details,
      is_error: is_error,
      timestamp: System.system_time(:millisecond)
    }

    context = %{context | messages: context.messages ++ [tool_result_message]}
    new_messages = new_messages ++ [tool_result_message]
    results = [tool_result_message | results]

    EventStream.push(stream, {:message_start, tool_result_message})
    EventStream.push(stream, {:message_end, tool_result_message})

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

  # ============================================================================
  # Private: Helpers
  # ============================================================================

  defp default_stream_fn(model, context, options) do
    Ai.stream(model, context, options)
  end

  # Ai.EventStream can stop immediately on cancel, which can raise on :take
  # (:noproc, :shutdown, or :normal depending on timing).
  # Wrap the take loop to treat those exits as a canceled terminal event.
  defp ai_events(response_stream) do
    Stream.resource(
      fn -> {:active, response_stream} end,
      fn
        {:halting, _stream} ->
          {:halt, nil}

        {:active, stream} ->
          case safe_ai_take(stream) do
            {:event, event} ->
              if terminal_ai_event?(event) do
                {[event], {:halting, stream}}
              else
                {[event], {:active, stream}}
              end

            :done ->
              {:halt, nil}
          end
      end,
      fn _acc -> :ok end
    )
  end

  defp safe_ai_take(stream) do
    try do
      GenServer.call(stream, :take, :infinity)
    catch
      :exit, {:noproc, _} ->
        {:event, {:canceled, :canceled}}

      :exit, {:normal, _} ->
        {:event, {:canceled, :canceled}}

      :exit, {:shutdown, _} ->
        {:event, {:canceled, :canceled}}
    end
  end

  defp terminal_ai_event?({:done, _reason, _message}), do: true
  defp terminal_ai_event?({:error, _reason, _message}), do: true
  defp terminal_ai_event?({:canceled, _reason}), do: true
  defp terminal_ai_event?(_event), do: false

  defp maybe_put_loop_abort_signal(signal) when is_reference(signal) do
    Process.put(@loop_abort_signal_pd_key, signal)
  end

  defp maybe_put_loop_abort_signal(_signal), do: :ok

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp transform_messages(context, %AgentLoopConfig{transform_context: nil}, _signal) do
    {:ok, context.messages}
  end

  defp transform_messages(context, %AgentLoopConfig{transform_context: transform_fn}, signal) do
    case transform_fn.(context.messages, signal) do
      {:ok, transformed} -> {:ok, transformed}
      {:error, reason} -> {:error, reason}
      transformed -> {:ok, transformed}
    end
  end

  defp convert_messages(%AgentLoopConfig{convert_to_llm: convert_fn}, messages) do
    case convert_fn.(messages) do
      {:ok, converted} -> {:ok, converted}
      {:error, reason} -> {:error, reason}
      converted -> {:ok, converted}
    end
  end

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: nil}), do: []

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: get_fn}) do
    get_fn.() || []
  end

  defp get_follow_up_messages(%AgentLoopConfig{get_follow_up_messages: nil}), do: []

  defp get_follow_up_messages(%AgentLoopConfig{get_follow_up_messages: get_fn}) do
    get_fn.() || []
  end

  defp finalize_message(final_message, context, added, stream) do
    context =
      if added do
        update_last_message(context, final_message)
      else
        %{context | messages: context.messages ++ [final_message]}
      end

    if not added do
      EventStream.push(stream, {:message_start, copy_message(final_message)})
    end

    EventStream.push(stream, {:message_end, final_message})
    {final_message, context}
  end

  defp finalize_canceled_message(partial, context, added, stream, config, reason) do
    stop_reason =
      case reason do
        :aborted -> :aborted
        :canceled -> :aborted
        :user_abort -> :aborted
        _ -> :error
      end

    error_message = "Stream canceled: #{inspect(reason)}"

    final_message =
      case partial do
        %AssistantMessage{} = msg ->
          %{msg | stop_reason: stop_reason, error_message: error_message}

        _ ->
          build_error_message(config, stop_reason, error_message)
      end

    finalize_message(final_message, context, added, stream)
  end

  defp build_error_message(%AgentLoopConfig{} = config, stop_reason, error_text) do
    model = config.model || %{}

    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: ""}],
      api: Map.get(model, :api),
      provider: Map.get(model, :provider),
      model: Map.get(model, :id, ""),
      usage: %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: stop_reason,
      error_message: error_text,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp is_assistant_message?(%AssistantMessage{}), do: true
  defp is_assistant_message?(%{role: :assistant}), do: true
  defp is_assistant_message?(_), do: false

  defp get_tool_calls(%AssistantMessage{content: content}) do
    Enum.filter(content, fn
      %ToolCall{} -> true
      %{type: :tool_call} -> true
      _ -> false
    end)
  end

  defp get_tool_calls(_), do: []

  defp find_tool(tools, name) do
    Enum.find(tools, fn tool -> tool.name == name end)
  end

  defp convert_tools_to_llm(agent_tools) do
    Enum.map(agent_tools, fn %AgentTool{} = tool ->
      %Tool{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
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

  defp update_last_message(context, new_message) do
    messages = List.replace_at(context.messages, -1, new_message)
    %{context | messages: messages}
  end

  defp copy_message(%AssistantMessage{} = msg) do
    %{msg | content: msg.content}
  end

  defp copy_message(msg), do: msg

  # ============================================================================
  # Private: Telemetry Helpers
  # ============================================================================

  defp emit_loop_end_telemetry(new_messages, config, status) do
    start_time = Process.get(:agent_loop_start_time)
    duration = if start_time, do: System.monotonic_time() - start_time, else: nil

    LemonCore.Telemetry.emit(
      [:agent_core, :loop, :end],
      %{duration: duration, system_time: System.system_time()},
      %{
        message_count: length(new_messages),
        model: get_model_id(config),
        status: status
      }
    )
  end

  defp get_model_id(%AgentLoopConfig{model: nil}), do: nil
  defp get_model_id(%AgentLoopConfig{model: model}), do: Map.get(model, :id)
end
