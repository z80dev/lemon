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

  require Logger

  alias AgentCore.EventStream
  alias AgentCore.Loop.{Streaming, ToolCalls}
  alias AgentCore.Types.{AgentContext, AgentLoopConfig}

  alias Ai.Types.{
    AssistantMessage,
    ToolCall
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

    Logger.info(
      "AgentCore.Loop starting prompt_count=#{length(prompts)} message_count=#{length(context.messages)} " <>
        "tool_count=#{length(context.tools)} model=#{get_model_id(config)}"
    )

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

    Logger.info(
      "AgentCore.Loop continuing message_count=#{length(context.messages)} " <>
        "tool_count=#{length(context.tools)} model=#{get_model_id(config)}"
    )

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

    Logger.debug("AgentCore.Loop run_loop pending_steering=#{length(pending_messages)}")

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

      Logger.debug("AgentCore.Loop do_run_loop continue_outer follow_up=#{length(follow_up_messages)}")

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
      Logger.info("AgentCore.Loop early exit")
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
    Logger.debug("AgentCore.Loop do_inner_loop exit - no more tool calls or messages")
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

    Logger.debug("AgentCore.Loop do_inner_loop turn first_turn=#{first_turn} pending=#{length(pending_messages)}")

    # Process pending messages (inject before next assistant response)
    {context, new_messages, _cleared_pending} =
      process_pending_messages(context, new_messages, pending_messages, stream)

    # Stream assistant response
    case Streaming.stream_assistant_response(context, config, signal, stream_fn, stream) do
      {:ok, message, context} ->
        new_messages = new_messages ++ [message]

        case message.stop_reason do
          :aborted ->
            Logger.info("AgentCore.Loop turn aborted")
            EventStream.push(stream, {:turn_end, message, []})
            EventStream.cancel(stream, :assistant_aborted)
            {context, new_messages, [], false}

          :error ->
            EventStream.push(stream, {:turn_end, message, []})

            Logger.error(
              "AgentCore loop assistant_error " <>
                "provider=#{inspect(message.provider)} " <>
                "api=#{inspect(message.api)} " <>
                "model=#{inspect(message.model)} " <>
                "error_message=#{inspect(message.error_message)} " <>
                "content_blocks=#{length(message.content || [])}"
            )

            reason =
              case message.error_message do
                msg when is_binary(msg) and byte_size(msg) > 0 -> {:assistant_error, msg}
                _ -> :assistant_error
              end

            EventStream.error(stream, reason, %{new_messages: new_messages})
            {context, new_messages, [], false}

          _ ->
            Logger.debug("AgentCore.Loop turn completed stop_reason=#{message.stop_reason}")
            # Check for tool calls
            tool_calls = get_tool_calls(message)
            has_more_tool_calls = tool_calls != []

            {tool_results, steering_after_tools, context, new_messages} =
              if has_more_tool_calls do
                ToolCalls.execute_and_collect_tools(
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
  # Private: Helpers
  # ============================================================================

  defp maybe_put_loop_abort_signal(signal) when is_reference(signal) do
    Process.put(@loop_abort_signal_pd_key, signal)
  end

  defp maybe_put_loop_abort_signal(_signal), do: :ok

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: nil}), do: []

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: get_fn}) do
    get_fn.() || []
  end

  defp get_follow_up_messages(%AgentLoopConfig{get_follow_up_messages: nil}), do: []

  defp get_follow_up_messages(%AgentLoopConfig{get_follow_up_messages: get_fn}) do
    get_fn.() || []
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
