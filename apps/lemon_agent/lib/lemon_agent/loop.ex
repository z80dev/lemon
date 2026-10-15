defmodule LemonAgent.Loop do
  @moduledoc """
  Stateless agent loop functions for conversation management.

  This module implements the core agent loop logic that orchestrates:
  - Streaming LLM responses
  - Tool call execution
  - Steering message injection
  - Follow-up message handling

  The loop works with `LemonAgent.EventStream` to emit events for UI clients
  and returns the final list of new messages created during the run.

  ## Entry Points

  - `agent_loop/5` - Start a new agent loop with prompt messages
  - `agent_loop_continue/4` - Continue from an existing context

  ## Event Flow

  The loop emits events in a specific sequence:

      {:agent_start}
      {:tool_schema_snapshot, snapshot}
      {:turn_start}
      {:loop_state_transition, nil, :initializing, %{phase: :run_start}}
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
      {:loop_budget_exhausted, details}
      ... (more turns if tool calls or steering)
      {:agent_end, new_messages}

  ## Abort Handling

  The `signal` parameter is a reference that can be used for abort handling.
  Check for abort by monitoring the signal or using Process messages.
  """

  require Logger

  alias LemonAgent.{AbortSignal, AutoThinking, Budget, EventStream}
  alias LemonAgent.Loop.{StateMachine, Streaming, ToolCalls}
  alias LemonAgent.ModelRuntime.StreamOptions
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentToolResult, ToolSchemaSnapshot}

  alias LemonAi.Types.{
    AssistantMessage,
    TextContent,
    ToolCall,
    ToolResultMessage
  }

  @loop_abort_signal_pd_key :agent_abort_signal
  @loop_state_pd_key :agent_loop_state
  @usage_budget_pd_key :agent_usage_budget

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
  - `stream_fn` - Optional custom stream function (defaults to `LemonAi.stream/3`)

  ## Returns

  An `EventStream` that will emit agent events and complete with
  `{:ok, new_messages}` where `new_messages` contains only the messages
  created during this run (not the original context messages).

  ## Examples

      context = AgentContext.new(system_prompt: "You are helpful")
      config = %AgentLoopConfig{model: model, convert_to_llm: &convert/1}
      prompt = %LemonAi.Types.UserMessage{content: "Hello", timestamp: now()}

      stream = LemonAgent.Loop.agent_loop([prompt], context, config, nil, nil)

      for event <- EventStream.events(stream) do
        IO.inspect(event)
      end
  """
  @spec agent_loop(
          [LemonAgent.Types.agent_message()],
          AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil
        ) :: EventStream.t()
  def agent_loop(prompts, context, config, signal, stream_fn) do
    agent_loop(prompts, context, config, signal, stream_fn, nil)
  end

  @spec agent_loop(
          [LemonAgent.Types.agent_message()],
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
    case Task.Supervisor.start_child(LemonAgent.LoopTaskSupervisor, fn ->
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
          [LemonAgent.Types.agent_message()],
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
      stream = LemonAgent.Loop.agent_loop_continue(context, config, nil, nil)
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

    if assistant_message?(last_message) do
      raise ArgumentError, "Cannot continue from message role: assistant"
    end

    {:ok, stream} =
      if owner do
        EventStream.start_link(owner: owner, timeout: :infinity)
      else
        EventStream.start_link(timeout: :infinity)
      end

    case Task.Supervisor.start_child(LemonAgent.LoopTaskSupervisor, fn ->
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
      "LemonAgent.Loop starting prompt_count=#{length(prompts)} message_count=#{length(context.messages)} " <>
        "tool_count=#{length(context.tools)} model=#{get_model_id(config)}"
    )

    LemonCore.Telemetry.emit(
      [:lemon_agent, :loop, :start],
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

    config = AutoThinking.reset_for_user_prompts(config, prompts)
    {current_context, config, snapshot} = snapshot_tool_schema(current_context, config)

    # Emit initial events
    EventStream.push(stream, {:agent_start})
    config = initialize_budget(config, stream, true)
    emit_tool_schema_snapshot(stream, snapshot)
    EventStream.push(stream, {:turn_start})
    reset_loop_state()
    transition_loop_state(stream, :initializing, %{phase: :run_start})

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
      "LemonAgent.Loop continuing message_count=#{length(context.messages)} " <>
        "tool_count=#{length(context.tools)} model=#{get_model_id(config)}"
    )

    LemonCore.Telemetry.emit(
      [:lemon_agent, :loop, :start],
      %{system_time: System.system_time()},
      %{
        prompt_count: 0,
        message_count: length(context.messages),
        tool_count: length(context.tools),
        model: get_model_id(config)
      }
    )

    new_messages = []
    {current_context, config, snapshot} = snapshot_tool_schema(context, config)

    EventStream.push(stream, {:agent_start})
    config = initialize_budget(config, stream, false)
    emit_tool_schema_snapshot(stream, snapshot)
    EventStream.push(stream, {:turn_start})
    reset_loop_state()
    transition_loop_state(stream, :initializing, %{phase: :run_continue})

    run_loop(current_context, new_messages, config, signal, stream_fn, stream)
  end

  # ============================================================================
  # Private: Main Loop
  # ============================================================================

  defp run_loop(context, new_messages, config, signal, stream_fn, stream) do
    # Check for steering messages at start (user may have typed while waiting).
    # Clear the redirect flag BEFORE draining: a redirect cast processed before
    # the drain has its correction included here (a set flag is then cleared
    # harmlessly, worst case one immediate cancel/retry with the correction
    # already in context); one processed after the drain keeps its flag, so
    # the model call is canceled mid-stream and retried with the correction.
    # Clearing after the drain would swallow that second case silently.
    AbortSignal.clear_redirect(signal)
    pending_messages = get_steering_messages(config, signal)

    Logger.debug("LemonAgent.Loop run_loop pending_steering=#{length(pending_messages)}")

    do_run_loop(context, new_messages, config, signal, stream_fn, stream, pending_messages, true)
  end

  defp snapshot_tool_schema(context, %AgentLoopConfig{} = config) do
    snapshot = config.tool_schema_snapshot || ToolSchemaSnapshot.new(context.tools)
    context = %{context | tools: snapshot.tools}
    config = %{config | tool_schema_snapshot: snapshot}

    {context, config, snapshot}
  end

  defp emit_tool_schema_snapshot(stream, %ToolSchemaSnapshot{} = snapshot) do
    EventStream.push(stream, {:tool_schema_snapshot, snapshot})

    LemonCore.Telemetry.emit(
      [:lemon_agent, :tool_schema_snapshot, :created],
      %{system_time: System.system_time()},
      %{
        snapshot_id: snapshot.id,
        fingerprint: snapshot.fingerprint,
        tool_count: length(snapshot.tool_names),
        tool_names: snapshot.tool_names
      }
    )
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
        _steering_after_tools = nil,
        _tool_turn_count = 0
      )

    if continue_outer do
      # Check for follow-up messages
      follow_up_messages = get_follow_up_messages(config)

      Logger.debug(
        "LemonAgent.Loop do_run_loop continue_outer follow_up=#{length(follow_up_messages)}"
      )

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
        transition_loop_state(stream, :finalizing, %{reason: :completed})
        emit_loop_end_telemetry(new_messages, config, :completed)
        EventStream.push(stream, {:agent_end, new_messages})
        EventStream.complete(stream, new_messages)
      end
    else
      # Inner loop signaled early exit (error/abort)
      Logger.info("LemonAgent.Loop early exit")
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
         _steering_after_tools,
         _tool_turn_count
       )
       when pending_messages == [] do
    # Exit condition: no more tool calls and no pending messages
    Logger.debug("LemonAgent.Loop do_inner_loop exit - no more tool calls or messages")
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
         _steering_after_tools,
         tool_turn_count
       ) do
    # Emit turn_start if not first turn
    if not first_turn do
      EventStream.push(stream, {:turn_start})
    end

    Logger.debug(
      "LemonAgent.Loop do_inner_loop turn first_turn=#{first_turn} pending=#{length(pending_messages)}"
    )

    # Process pending messages (inject before next assistant response)
    config = AutoThinking.reset_for_user_prompts(config, pending_messages)

    {context, new_messages, _cleared_pending} =
      process_pending_messages(context, new_messages, pending_messages, stream)

    transition_loop_state(stream, :await_model, %{first_turn: first_turn})

    config = refresh_model(config)

    # Classification runs in the model-loop task and is cached per user prompt,
    # not repeated by tool turns or provider retries.
    message_count_before_response = length(context.messages)

    {response, config} =
      case budget_check(config) do
        nil ->
          case AutoThinking.prepare_turn(config, context.messages, signal) do
            {:ok, prepared_config} ->
              {Streaming.stream_assistant_response(
                 context,
                 prepared_config,
                 signal,
                 stream_fn,
                 stream
               ), prepared_config}

            {:error, :aborted} = error ->
              {error, config}
          end

        details ->
          {{:error, {:budget_exceeded, details}}, config}
      end

    case response do
      {:ok, message, context} ->
        new_messages = new_messages ++ Enum.drop(context.messages, message_count_before_response)
        transition_loop_state(stream, :normalizing_response, %{stop_reason: message.stop_reason})

        case {budget_check(config), message.stop_reason} do
          {%{} = details, _stop_reason} ->
            stop_usage_budget(context, new_messages, message, details, stream)

          {nil, :aborted} ->
            Logger.info("LemonAgent.Loop turn aborted")
            transition_loop_state(stream, :aborted, %{reason: :assistant_aborted})
            EventStream.push(stream, {:turn_end, message, []})
            EventStream.cancel(stream, :assistant_aborted)
            {context, new_messages, [], false}

          {nil, :redirected} ->
            # The in-flight model request was canceled by a redirect. Drop the
            # partial assistant message from the loop context (prior completed
            # messages/tool results are preserved), clear the redirect flag,
            # drain the queued correction, and retry the model call.
            Logger.info("LemonAgent.Loop turn redirected")
            context = drop_trailing_message(context, message)
            EventStream.push(stream, {:turn_end, message, []})
            AbortSignal.clear_redirect(signal)

            pending_messages = get_steering_messages(config, signal)

            if aborted?(signal) do
              transition_loop_state(stream, :aborted, %{reason: :assistant_aborted})
              EventStream.cancel(stream, :assistant_aborted)
              {context, new_messages, [], false}
            else
              do_inner_loop(
                context,
                new_messages,
                config,
                signal,
                stream_fn,
                stream,
                pending_messages,
                false,
                false,
                nil,
                tool_turn_count
              )
            end

          {nil, :error} ->
            transition_loop_state(stream, :recovering_provider_error, %{reason: :assistant_error})
            EventStream.push(stream, {:turn_end, message, []})

            Logger.error(
              "LemonAgent loop assistant_error " <>
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
            transition_loop_state(stream, :finalizing, %{reason: :assistant_error})
            {context, new_messages, [], false}

          _ ->
            Logger.debug("LemonAgent.Loop turn completed stop_reason=#{message.stop_reason}")
            # Check for tool calls
            tool_calls = get_tool_calls(message)
            has_more_tool_calls = tool_calls != []

            {tool_results, steering_after_tools, context, new_messages} =
              if has_more_tool_calls do
                transition_loop_state(stream, :executing_tools, %{
                  tool_call_count: length(tool_calls)
                })

                ToolCalls.execute_and_collect_tools(
                  context,
                  new_messages,
                  tool_calls,
                  config,
                  signal,
                  stream
                )
                |> then(fn result ->
                  transition_loop_state(stream, :awaiting_tool_results, %{
                    tool_call_count: length(tool_calls)
                  })

                  result
                end)
              else
                {[], nil, context, new_messages}
              end

            EventStream.push(stream, {:turn_end, message, tool_results})

            tool_turn_count =
              if has_more_tool_calls, do: tool_turn_count + 1, else: tool_turn_count

            if max_tool_turns_exhausted?(config, has_more_tool_calls, tool_turn_count) do
              complete_tool_loop_budget(context, new_messages, config, stream, tool_turn_count)
            else
              # Get steering messages after turn completes. Flag-clear-before-
              # drain, same reasoning as in run_loop/6: when steering_after_tools
              # is non-empty the clear already happened before ToolCalls' drain.
              pending_messages =
                if steering_after_tools && steering_after_tools != [] do
                  steering_after_tools
                else
                  AbortSignal.clear_redirect(signal)
                  get_steering_messages(config, signal)
                end

              if aborted?(signal) do
                transition_loop_state(stream, :aborted, %{reason: :assistant_aborted})
                EventStream.cancel(stream, :assistant_aborted)
                {context, new_messages, [], false}
              else
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
                  nil,
                  tool_turn_count
                )
              end
            end
        end

      {:error, {:budget_exceeded, details}} ->
        stop_usage_budget(context, new_messages, nil, details, stream)

      {:error, :aborted} ->
        transition_loop_state(stream, :aborted, %{reason: :assistant_aborted})
        EventStream.cancel(stream, :assistant_aborted)
        {context, new_messages, [], false}

      {:error, reason} ->
        transition_loop_state(stream, :recovering_provider_error, %{reason: reason})
        EventStream.error(stream, reason, new_messages)
        transition_loop_state(stream, :finalizing, %{reason: :stream_error})
        {context, new_messages, [], false}
    end
  end

  @doc false
  @spec refresh_model(AgentLoopConfig.t()) :: AgentLoopConfig.t()
  def refresh_model(config) do
    model = if config.get_model, do: config.get_model.(), else: config.model
    options_model = config.stream_options_model || config.model

    if model == options_model do
      if model == config.model, do: config, else: %{config | model: model}
    else
      effort =
        if config.resolve_thinking,
          do: config.resolved_thinking || AutoThinking.default_effort(model),
          else: config.stream_options.reasoning

      options =
        cond do
          config.resolve_stream_options ->
            config.resolve_stream_options.(model, options_model, config.stream_options)

          model.provider != options_model.provider ->
            StreamOptions.sanitize_for_provider_switch(config.stream_options)

          true ->
            config.stream_options
        end

      options = %{options | reasoning: AutoThinking.clamp_effort(model, effort)}

      %{config | model: model, stream_options_model: model, stream_options: options}
    end
  end

  # Budget state is loop-task-local, so retries and recursive turns share it
  # without an extra process or expanding every streaming return tuple.
  defp initialize_budget(config, stream, reset_run?) do
    budget =
      cond do
        config.budget && reset_run? ->
          Budget.new(config.budget.limits, config.budget.session_usage)

        config.budget ->
          config.budget

        Budget.enabled?(config.budget_limits) ->
          Budget.new(config.budget_limits, config.budget_usage)

        true ->
          nil
      end

    scope = Map.get(config.budget_limits || %{}, :scope)
    if scope && reset_run?, do: LemonAgent.BudgetScope.begin_run(scope)

    warning = Budget.unpriced_warning(config.budget_limits || %{}, config.model)

    if warning do
      Logger.warning(warning)
      EventStream.push(stream, {:budget_warning, %{message: warning}})
    end

    if budget do
      Process.put(@usage_budget_pd_key, budget)
      emit_budget_usage(stream, budget)
      %{config | budget: budget}
    else
      config
    end
  end

  @doc false
  def budget_check(config, projected \\ %{tokens: 0, cost_usd: 0.0})
  def budget_check(%AgentLoopConfig{budget: nil}, _projected), do: nil

  def budget_check(config, projected) do
    budget = Process.get(@usage_budget_pd_key, config.budget)

    case Budget.check(budget, projected) ||
           LemonAgent.BudgetScope.check(Map.get(budget.limits, :scope), projected) do
      nil -> nil
      details -> Map.put(details, :provider_usage, Map.take(budget, [:run_usage, :session_usage]))
    end
  end

  @doc false
  def record_budget_usage(%AgentLoopConfig{budget: nil}, _message, _stream), do: :ok

  def record_budget_usage(config, message, stream) do
    budget = Budget.record_message(Process.get(@usage_budget_pd_key, config.budget), message)
    Process.put(@usage_budget_pd_key, budget)
    scope = Map.get(budget.limits, :scope)
    if scope, do: LemonAgent.BudgetScope.update(scope, budget)
    emit_budget_usage(stream, budget)
  end

  defp emit_budget_usage(stream, budget) do
    EventStream.push(
      stream,
      {:usage_budget_updated, %{run_usage: budget.run_usage, session_usage: budget.session_usage}}
    )
  end

  defp stop_usage_budget(context, new_messages, message, details, stream) do
    tool_results =
      if message do
        Enum.map(get_tool_calls(message), fn call ->
          result = %AgentToolResult{
            content: [%TextContent{text: details.message}],
            details: details,
            is_error: true
          }

          rejected = %ToolResultMessage{
            tool_call_id: call.id,
            tool_name: call.name,
            content: result.content,
            details: details,
            is_error: true,
            timestamp: System.system_time(:millisecond)
          }

          EventStream.push(stream, {:tool_execution_end, call.id, call.name, result, true})
          EventStream.push(stream, {:message_start, rejected})
          EventStream.push(stream, {:message_end, rejected})
          rejected
        end)
      else
        []
      end

    context = %{context | messages: context.messages ++ tool_results}
    new_messages = new_messages ++ tool_results
    if message, do: EventStream.push(stream, {:turn_end, message, tool_results})
    EventStream.push(stream, {:budget_exceeded, details})
    transition_loop_state(stream, :finalizing, %{reason: :budget_exceeded})
    EventStream.error(stream, {:budget_exceeded, details}, %{new_messages: new_messages})
    {context, new_messages, [], false}
  end

  defp process_pending_messages(context, new_messages, [], _stream) do
    {context, new_messages, []}
  end

  defp process_pending_messages(context, new_messages, pending_messages, stream) do
    {context, pending_messages} = apply_queued_system_prompt(context, pending_messages)

    for message <- pending_messages do
      EventStream.push(stream, {:message_start, message})
      EventStream.push(stream, {:message_end, message})
    end

    context = %{context | messages: context.messages ++ pending_messages}
    new_messages = new_messages ++ pending_messages

    {context, new_messages, []}
  end

  defp max_tool_turns_exhausted?(config, has_more_tool_calls, tool_turn_count) do
    case resolve_max_tool_turns(config) do
      :infinity -> false
      max_tool_turns -> has_more_tool_calls and tool_turn_count >= max_tool_turns
    end
  end

  defp resolve_max_tool_turns(%AgentLoopConfig{max_tool_turns: :infinity}), do: :infinity

  defp resolve_max_tool_turns(%AgentLoopConfig{max_tool_turns: max_tool_turns})
       when is_integer(max_tool_turns) do
    max(max_tool_turns, 1)
  end

  defp resolve_max_tool_turns(%AgentLoopConfig{}), do: 25

  defp complete_tool_loop_budget(context, new_messages, config, stream, tool_turn_count) do
    max_tool_turns = resolve_max_tool_turns(config)

    details = %{
      reason: :max_tool_turns_exhausted,
      max_tool_turns: max_tool_turns,
      tool_turns: tool_turn_count
    }

    EventStream.push(stream, {:loop_budget_exhausted, details})
    transition_loop_state(stream, :finalizing, %{reason: :max_tool_turns_exhausted})

    message = %AssistantMessage{
      role: :assistant,
      content: [
        %TextContent{
          type: :text,
          text:
            "I stopped because the maximum tool-call turn budget was reached before a final answer."
        }
      ],
      api: get_model_api(config),
      provider: get_model_provider(config),
      model: get_model_id(config),
      stop_reason: :error,
      error_message: "max_tool_turns_exhausted",
      timestamp: System.system_time(:millisecond)
    }

    context = %{context | messages: context.messages ++ [message]}
    new_messages = new_messages ++ [message]

    EventStream.push(stream, {:message_start, message})
    EventStream.push(stream, {:message_end, message})
    EventStream.push(stream, {:agent_end, new_messages})
    EventStream.complete(stream, new_messages)

    {context, new_messages, [], false}
  end

  defp apply_queued_system_prompt(context, pending_messages) do
    {messages, latest_system_prompt} =
      Enum.map_reduce(pending_messages, nil, fn
        %{message: message, system_prompt: prompt}, _latest when is_binary(prompt) ->
          {message, prompt}

        %{message: message}, latest ->
          {message, latest}

        message, latest ->
          {message, latest}
      end)

    context =
      case latest_system_prompt do
        prompt when is_binary(prompt) and prompt != "" -> %{context | system_prompt: prompt}
        _ -> context
      end

    {context, messages}
  end

  # ============================================================================
  # Private: Helpers
  # ============================================================================

  defp maybe_put_loop_abort_signal(signal) when is_reference(signal) do
    Process.put(@loop_abort_signal_pd_key, signal)
  end

  defp maybe_put_loop_abort_signal(_signal), do: :ok

  defp reset_loop_state do
    Process.delete(@loop_state_pd_key)
    :ok
  end

  defp transition_loop_state(stream, next_state, metadata) do
    current_state = Process.get(@loop_state_pd_key)
    state = StateMachine.transition!(current_state, next_state)
    Process.put(@loop_state_pd_key, state)

    EventStream.push(stream, {:loop_state_transition, current_state, state, metadata})

    LemonCore.Telemetry.emit(
      [:lemon_agent, :loop, :state_transition],
      %{system_time: System.system_time()},
      Map.merge(metadata, %{from: current_state, to: state})
    )

    state
  end

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: nil}), do: []

  defp get_steering_messages(%AgentLoopConfig{get_steering_messages: get_fn}) do
    get_fn.() || []
  end

  defp get_steering_messages(%AgentLoopConfig{} = config, signal) do
    if aborted?(signal) do
      []
    else
      messages = get_steering_messages(config)
      if aborted?(signal), do: [], else: messages
    end
  end

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp get_follow_up_messages(%AgentLoopConfig{get_follow_up_messages: nil}), do: []

  defp get_follow_up_messages(%AgentLoopConfig{get_follow_up_messages: get_fn}) do
    get_fn.() || []
  end

  defp assistant_message?(%AssistantMessage{}), do: true
  defp assistant_message?(%{role: :assistant}), do: true
  defp assistant_message?(_), do: false

  # Remove `message` from the end of the context, where the streaming pass
  # finalized it. Used by the redirect path to discard the canceled partial.
  defp drop_trailing_message(context, message) do
    if List.last(context.messages) == message do
      %{context | messages: List.delete_at(context.messages, -1)}
    else
      context
    end
  end

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
      [:lemon_agent, :loop, :end],
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

  defp get_model_api(%AgentLoopConfig{model: nil}), do: nil
  defp get_model_api(%AgentLoopConfig{model: model}), do: Map.get(model, :api)

  defp get_model_provider(%AgentLoopConfig{model: nil}), do: nil
  defp get_model_provider(%AgentLoopConfig{model: model}), do: Map.get(model, :provider)
end
