defmodule LemonAgent.Loop.Streaming do
  @moduledoc false

  alias LemonAgent.AbortSignal
  alias LemonAgent.EventStream
  alias LemonAgent.Loop
  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Loop.ToolStream
  alias LemonAgent.Loop.TranscriptValidator
  alias LemonAgent.Security.UntrustedToolBoundary
  alias LemonAgent.ModelRuntime.ProviderFailover
  alias LemonAgent.Types.{AgentLoopConfig, AgentTool}

  alias LemonAi.Retry
  alias LemonAi.StreamAccumulator

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    TextContent,
    Tool,
    ToolCall
  }

  @max_retry_after_ms 120_000
  @max_continuations 3
  @continuation_key {__MODULE__, :continuation}
  @attempts_key {__MODULE__, :attempts}

  defp continuation_state(stream) do
    case Process.get(@continuation_key) do
      {^stream, count} -> count
      _ -> 0
    end
  end

  # One upstream-attempt budget per request, shared by the loop's retries and
  # every provider/credential candidate failover tries: `max_retries + 1`
  # attempts, and at least two so disabling retries keeps one failover
  # attempt. The loop's own retries still stop at `max_retries`. The counter
  # is an atomics cell so the failover task can charge it.
  defp attempt_counter do
    case Process.get(@attempts_key) do
      nil ->
        counter = :atomics.new(1, [])
        Process.put(@attempts_key, counter)
        counter

      counter ->
        counter
    end
  end

  defp attempt_limit(config), do: max(config.max_retries, 1) + 1

  defp attempts_spent?(config),
    do: :atomics.get(attempt_counter(), 1) >= attempt_limit(config)

  @spec stream_assistant_response(
          LemonAgent.Types.AgentContext.t(),
          AgentLoopConfig.t(),
          AbortSignal.t() | nil,
          AgentLoopConfig.stream_fn() | nil,
          EventStream.t()
        ) :: {:ok, AssistantMessage.t(), LemonAgent.Types.AgentContext.t()} | {:error, term()}
  def stream_assistant_response(context, config, signal, stream_fn, stream) do
    AbortSignal.subscribe(signal)
    Process.put(@attempts_key, :atomics.new(1, []))

    try do
      system_prompt = context.system_prompt
      result = retry_response(context, config, signal, stream_fn, stream, 0)

      case result do
        {:ok, message, updated} -> {:ok, message, %{updated | system_prompt: system_prompt}}
        other -> other
      end
    after
      Process.delete(@attempts_key)
      AbortSignal.unsubscribe(signal)
    end
  end

  defp retry_response(context, config, signal, stream_fn, stream, retries_done) do
    result =
      case Loop.budget_check(config) do
        nil -> stream_once(context, config, signal, stream_fn, stream)
        details -> {:error, {:budget_exceeded, details}}
      end

    case result do
      {:failed, %{error_message: reason} = message, failed_context, added, committed}
      when reason in ["empty_assistant_response", "malformed_tool_arguments"] ->
        continue_response(
          context,
          config,
          signal,
          stream_fn,
          stream,
          retries_done,
          message,
          failed_context,
          added,
          committed
        )

      {:failed, message, failed_context, added, committed} ->
        committed = committed or committed_content?(message)
        details = message.error_details || LemonAi.Error.to_error_details(error_text(message))
        message = %{message | error_details: Map.put(details, :output_committed, committed)}

        decision =
          case Loop.budget_check(config) do
            nil ->
              if committed,
                do: :stop,
                else: retry_delay(message, config, retries_done)

            details ->
              {:budget_stop, details}
          end

        case decision do
          {:ok, delay_ms} ->
            retry_attempt(
              context,
              config,
              signal,
              stream_fn,
              stream,
              retries_done,
              message,
              delay_ms
            )

          {:budget_stop, _details} ->
            finish_retry(stream, retries_done, false, false)
            # Keep the reported tool calls: the outer loop pairs them with
            # explicit budget rejection results, never executing them.
            {message, context} = finalize_message(message, failed_context, added, stream, config)
            {:ok, message, context}

          :stop ->
            finish_retry(stream, retries_done, false, false)
            message = strip_tool_calls(message)
            {message, context} = finalize_message(message, failed_context, added, stream, config)
            {:ok, message, context}
        end

      {:error, reason} ->
        case budget_retry_delay(reason, config, retries_done) do
          {:ok, delay_ms} ->
            retry_attempt(
              context,
              config,
              signal,
              stream_fn,
              stream,
              retries_done,
              reason,
              delay_ms
            )

          {:budget_stop, details} ->
            finish_retry(stream, retries_done, false, false)
            {:error, {:budget_exceeded, details}}

          :stop ->
            finish_retry(stream, retries_done, false, false)
            result
        end

      {:ok, message, _context} ->
        finish_retry(
          stream,
          retries_done,
          message.stop_reason not in [:error, :aborted, :redirected],
          message.stop_reason in [:aborted, :redirected]
        )

        result
    end
  end

  defp continue_response(
         context,
         config,
         signal,
         stream_fn,
         stream,
         retries_done,
         message,
         failed_context,
         added,
         committed
       ) do
    count = continuation_state(stream)

    if count < @max_continuations and
         is_nil(Loop.budget_check(config)) and not aborted?(signal) and
         not redirect_requested?(signal) do
      attempt = count + 1
      Process.put(@continuation_key, {stream, attempt})
      empty = message.error_message == "empty_assistant_response"
      reason = if empty, do: "empty reply", else: "malformed tool arguments"

      EventStream.push!(
        stream,
        {:provider_retry,
         %{
           attempt: attempt,
           max_retries: @max_continuations,
           delay_ms: 0,
           category: :continuation,
           reason: "#{reason}, continuing (#{attempt}/#{@max_continuations})",
           provider: config.model.provider,
           model: config.model.id
         }}
      )

      # Close committed output once and retain it in provider context. Never
      # replay an earlier request or leave an unpaired malformed tool call.
      context =
        if committed do
          previous = Map.get(message.error_details || %{}, :original_message, message)

          retained = %{
            strip_tool_calls(previous)
            | stop_reason: :stop,
              error_message: nil,
              error_details: nil
          }

          {_retained, updated} = finalize_message(retained, failed_context, added, stream, config)
          updated
        else
          context
        end

      nudge =
        if empty do
          "Your previous reply was empty. Continue from where you left off."
        else
          "Your previous tool call had invalid arguments: #{message.error_details[:argument_errors]}. " <>
            "Re-issue the tool call with valid JSON arguments matching its schema."
        end

      # Request-local system guidance is neither a human message nor persisted
      # transcript content. Committed text remains in the assistant history.
      suffix =
        "\n\n[Internal continuation]\n" <>
          nudge <> "\nAppend to any previous output; do not repeat it."

      prompt =
        case context.system_prompt do
          blocks when is_list(blocks) ->
            blocks ++ [%{text: suffix, directory_derived: true}]

          text ->
            (text || "") <> suffix
        end

      context = %{context | system_prompt: prompt}

      # A continuation is a new request with its own attempt budget.
      :atomics.put(attempt_counter(), 1, 0)
      result = retry_response(context, config, signal, stream_fn, stream, retries_done)

      finish_retry(
        stream,
        attempt,
        match?(
          {:ok, %{stop_reason: reason}, _}
          when reason not in [:error, :aborted, :redirected],
          result
        ),
        false
      )

      result
    else
      message =
        case message.error_message do
          "malformed_tool_arguments" -> message.error_details.original_message
          _ -> strip_tool_calls(message)
        end

      {message, context} = finalize_message(message, failed_context, added, stream, config)
      {:ok, message, context}
    end
  end

  defp budget_retry_delay({:budget_exceeded, details}, _config, _retries_done),
    do: {:budget_stop, details}

  defp budget_retry_delay(error, config, retries_done) do
    case Loop.budget_check(config) do
      nil -> retry_delay(error, config, retries_done)
      details -> {:budget_stop, details}
    end
  end

  defp retry_attempt(context, config, signal, stream_fn, stream, retries_done, error, delay_ms) do
    attempt = retries_done + 1

    EventStream.push!(
      stream,
      {:provider_retry,
       %{
         attempt: attempt,
         max_retries: config.max_retries,
         delay_ms: delay_ms,
         retry_after_ms: retry_after_ms(error),
         category: LemonAi.Error.classify(error),
         reason: LemonAi.Error.format_error(error_text(error)),
         provider: Map.get(config.model || %{}, :provider),
         model: Map.get(config.model || %{}, :id)
       }}
    )

    case Retry.wait(delay_ms,
           cancelled?: fn ->
             cond do
               aborted?(signal) -> :aborted
               redirect_requested?(signal) -> :redirected
               true -> false
             end
           end,
           cancel_messages: [
             {:lemon_abort, signal, :abort},
             {:lemon_abort, signal, :redirect}
           ],
           cancel_message_requires_state: true,
           sleep_fun: LemonAi.Provider.retry_policy(config.stream_options).sleep_fun
         ) do
      :ok ->
        retry_response(context, config, signal, stream_fn, stream, attempt)

      {:error, reason} ->
        finish_retry(stream, attempt, false, true)

        {message, context} =
          finalize_canceled_message(
            build_error_message(config, :error, nil)
            |> Map.put(:error_details, %{provider_invoked: false}),
            context,
            false,
            stream,
            config,
            reason
          )

        {:ok, message, context}
    end
  end

  defp retry_delay(error, config, retries_done) do
    policy =
      config.stream_options
      |> LemonAi.Provider.retry_policy()
      |> Map.merge(%{
        max_attempts: config.max_retries + 1,
        base_delay_ms: config.retry_base_delay_ms,
        max_delay_ms: config.retry_max_delay_ms,
        max_retry_after_ms: @max_retry_after_ms,
        classify: &LemonAi.Error.classify/1,
        jitter: :none
      })
      |> Retry.policy()

    if Retry.retry_allowed?(retries_done, policy) and LemonAi.Error.retryable?(error) and
         not attempts_spent?(config) do
      case Retry.retry_delay_ms(error, retries_done, policy, retry_after_ms(error)) do
        :give_up -> :stop
        delay -> {:ok, delay}
      end
    else
      :stop
    end
  end

  defp error_text(%AssistantMessage{error_message: message}), do: message
  defp error_text(error), do: error

  defp retry_after_ms(error),
    do: Retry.error_retry_after_ms(error)

  defp finish_retry(_stream, 0, _success, _canceled), do: :ok

  defp finish_retry(stream, attempt, success, canceled) do
    EventStream.push!(
      stream,
      {:provider_retry_end, %{attempt: attempt, success: success, canceled: canceled}}
    )
  end

  defp stream_once(context, config, signal, stream_fn, stream) do
    # Calls streamed by an earlier attempt or turn will never execute now.
    ToolStream.settle()
    record_system_prompt(context, config, stream)

    if aborted?(signal) do
      abort_message = build_error_message(config, :aborted, "Request was aborted")
      {abort_message, context} = finalize_message(abort_message, context, false, stream, config)
      {:ok, abort_message, context}
    else
      config = Loop.refresh_model(config)

      # NOTE: the redirect flag is deliberately NOT cleared here. The loop
      # clears it immediately BEFORE each steering drain (see
      # LemonAgent.Loop / LemonAgent.Loop.ToolCalls): a redirect cast that
      # lands after a drain keeps its flag set, so the in-stream check below
      # cancels this call and the loop retries with the correction. Clearing
      # here — after the drain — could swallow a redirect whose correction is
      # still sitting undrained in the steering queue, silently delaying it a
      # full turn.

      # The untrusted fence runs last, on the provider-bound messages that
      # `convert_to_llm` produced, so no caller transform or conversion can
      # reintroduce an unfenced tool result.
      with {:ok, messages} <- transform_messages(context, config, signal),
           :ok <- TranscriptValidator.validate(messages),
           {:ok, converted} <- convert_messages(config, messages),
           {:ok, llm_messages} <-
             UntrustedToolBoundary.transform(converted, signal,
               max_tool_result_bytes: config.tool_result_max_bytes
             ) do
        # Build LLM context
        llm_context = %Context{
          system_prompt: context.system_prompt,
          messages: llm_messages,
          tools: convert_tools_to_llm(context.tools, config.intent_tracing)
        }

        with {:ok, config} <- route_model(config, llm_context) do
          # Resolve stream function. Every upstream invocation is charged to the
          # request's attempt budget, including provider failover candidates.
          stream_function =
            budgeted_stream_fn(config, stream_fn || config.stream_fn || (&default_stream_fn/3))

          # Resolve API key (important for expiring tokens)
          api_key =
            case config.get_api_key do
              nil ->
                config.stream_options.api_key

              get_key_fn ->
                provider = config.model.provider

                resolved_key =
                  get_key_fn.(provider) ||
                    if(is_atom(provider), do: get_key_fn.(Atom.to_string(provider)))

                if config.stream_options.api_key_authoritative,
                  do: resolved_key,
                  else: resolved_key || config.stream_options.api_key
            end

          # The response loop is the sole retry owner. Every provider invocation
          # gets one upstream attempt, including when retries are disabled.
          provider_retry = Map.put(config.stream_options.provider_retry || %{}, :max_attempts, 1)
          options = %{config.stream_options | api_key: api_key, provider_retry: provider_retry}

          # Call the stream function (support {:ok, stream} or direct stream pid)
          case request_with_budget(config, llm_context, options, stream_function, stream) do
            {:ok, response_stream} ->
              process_stream_events(
                context,
                response_stream,
                stream,
                config,
                signal,
                llm_context,
                options
              )

            {:error, reason} ->
              case reason do
                %AssistantMessage{} = message ->
                  {:failed, %{message | stop_reason: :error}, context, false,
                   committed_content?(message)}

                _ ->
                  {:error, reason}
              end

            response_stream when is_pid(response_stream) ->
              process_stream_events(
                context,
                response_stream,
                stream,
                config,
                signal,
                llm_context,
                options
              )

            other ->
              {:error, {:invalid_stream, other}}
          end
        end
      else
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp route_model(%AgentLoopConfig{resolve_model: nil} = config, _context), do: {:ok, config}

  defp route_model(config, context) do
    with {:ok, model} <- config.resolve_model.(context, config.stream_options) do
      updated = Loop.refresh_model(%{config | model: model, get_model: nil})
      {:ok, %{updated | get_model: config.get_model}}
    end
  end

  defp budgeted_stream_fn(config, stream_function) do
    counter = attempt_counter()

    counted = fn model, context, options ->
      :atomics.add(counter, 1, 1)
      stream_function.(model, context, options)
    end

    ProviderFailover.wrap(counted, config.provider_failover,
      budget: {counter, attempt_limit(config)},
      check_model_cost: config.check_model_cost
    )
  end

  defp request_with_budget(config, context, options, stream_fn, stream) do
    with :ok <- check_model_cost(config, context, options) do
      projected =
        if config.budget,
          do: LemonAgent.Budget.project(config.model, context, options),
          else: %{tokens: 0, cost_usd: 0.0}

      case Loop.budget_check(config, projected) do
        nil ->
          result = stream_fn.(config.model, context, options)

          case result do
            {:ok, response_stream} when is_pid(response_stream) -> :ok
            response_stream when is_pid(response_stream) -> :ok
            {:error, reason} -> Loop.record_budget_usage(config, reason, stream)
            _ -> Loop.record_budget_usage(config, nil, stream)
          end

          result

        details ->
          {:error, {:budget_exceeded, details}}
      end
    end
  end

  defp check_model_cost(%AgentLoopConfig{check_model_cost: nil}, _context, _options), do: :ok

  defp check_model_cost(config, context, options),
    do: config.check_model_cost.(config.model, context, options)

  # Cancellation can race with a terminal provider event. Preserve its reported
  # usage even though cancellation still strips unexecuted tool calls.
  defp reported_terminal_message({kind, _reason, message}, partial)
       when kind in [:done, :error],
       do: reconcile_final_message(message, partial)

  defp reported_terminal_message(_event, partial), do: partial_snapshot(partial)

  defp process_stream_events(
         context,
         response_stream,
         stream,
         config,
         signal,
         llm_context,
         options
       ) do
    on_stream_rule = Map.get(config.hooks, :on_stream_rule)

    rules =
      case Map.get(config.hooks, :stream_rules, []) do
        resolve when is_function(resolve, 0) -> resolve.()
        rules -> rules
      end

    # Accumulate the partial message
    result =
      Enum.reduce_while(
        ai_events(response_stream, signal),
        {nil, context, false, false, %{}, LemonAgent.StreamRules.new(rules)},
        fn event, {partial, ctx, added, committed, raw_arguments, matcher} ->
          raw_arguments = accumulate_arguments(event, raw_arguments)
          event = validate_terminal_arguments(event, partial, ctx.tools, raw_arguments)

          {matcher, matched_rule} =
            feed_stream_rules(matcher, event, {partial, ctx, added, committed})

          if matched_rule != nil and is_function(on_stream_rule, 1) do
            case on_stream_rule.(matched_rule) do
              :ok -> AbortSignal.request_redirect(signal)
              {:error, :injection_limit} -> :ok
              {:error, reason} -> raise "stream rule injection failed: #{inspect(reason)}"
            end
          end

          cond do
            aborted?(signal) ->
              LemonAi.EventStream.cancel(response_stream, :aborted)
              partial = reported_terminal_message(event, partial)

              {final_message, final_ctx} =
                finalize_canceled_message(partial, ctx, added, stream, config, :aborted)

              {:halt, {:done, final_message, final_ctx}}

            redirect_requested?(signal) ->
              # Redirect cancels only this model request; the loop keeps prior
              # completed messages/tool results and retries with the queued
              # correction appended.
              LemonAi.EventStream.cancel(response_stream, :redirected)
              partial = reported_terminal_message(event, partial)

              {final_message, final_ctx} =
                finalize_canceled_message(partial, ctx, added, stream, config, :redirected)

              {:halt, {:done, final_message, final_ctx}}

            true ->
              case process_stream_event(event, partial, ctx, added, stream, config) do
                {:continue, new_partial, new_ctx, new_added} ->
                  committed = committed or output_event?(event)
                  ToolStream.observe(event, raw_arguments, new_ctx.tools, signal)
                  {:cont, {new_partial, new_ctx, new_added, committed, raw_arguments, matcher}}

                {:done, final_message, final_ctx} ->
                  {:halt, {:done, final_message, final_ctx}}

                {:failed, message, failed_context, failed_added} ->
                  {:halt, {:failed, message, failed_context, failed_added, committed}}
              end
          end
        end
      )

    case result do
      {:done, final_message, ctx} ->
        _ =
          LemonAi.PromptDiagnostics.record_llm_call(
            config.model,
            llm_context,
            options,
            final_message
          )

        {:ok, final_message, ctx}

      {:failed, message, ctx, added, committed} ->
        _ = LemonAi.PromptDiagnostics.record_llm_call(config.model, llm_context, options, message)
        {:failed, message, ctx, added, committed}

      {partial, ctx, added, committed, raw_arguments, _matcher} when partial != nil ->
        # Stream ended without done/error event - finalize with partial
        partial = partial |> partial_snapshot() |> normalize_arguments(ctx.tools, raw_arguments)
        partial = normalize_terminal_message(partial)
        Loop.record_budget_usage(config, partial, stream)

        result =
          if partial.stop_reason == :error do
            {:failed, partial, ctx, added, committed}
          else
            {final_message, final_ctx} = finalize_message(partial, ctx, added, stream, config)
            {:ok, final_message, final_ctx}
          end

        _ =
          LemonAi.PromptDiagnostics.record_llm_call(
            config.model,
            llm_context,
            options,
            partial
          )

        result

      _ ->
        Loop.record_budget_usage(config, nil, stream)
        {:error, :no_response}
    end
  catch
    :throw, {:event_stream_push_failed, reason} = failure ->
      LemonAi.EventStream.cancel(response_stream, reason)
      throw(failure)

    :throw, {:stream_rule_failed, error, {partial, ctx, added, committed}} ->
      # A rule that cannot evaluate this output fails the attempt without a
      # replay (it would fail identically); the provider call already ran, so
      # its reported usage is still charged.
      LemonAi.EventStream.cancel(response_stream, :stream_rule_failed)
      message = stream_rule_failure(error, partial, config)
      Loop.record_budget_usage(config, message, stream)
      _ = LemonAi.PromptDiagnostics.record_llm_call(config.model, llm_context, options, message)
      {:failed, message, ctx, added, committed}
  end

  defp feed_stream_rules(matcher, event, attempt) do
    LemonAgent.StreamRules.feed(matcher, event)
  rescue
    error in LemonAgent.StreamRules.Error -> throw({:stream_rule_failed, error, attempt})
  end

  defp stream_rule_failure(error, partial, config) do
    message = partial_snapshot(partial) || build_error_message(config, :error, nil)
    reason = Exception.message(error)

    %{
      message
      | stop_reason: :error,
        error_message: reason,
        error_details: %{
          category: :client,
          status: nil,
          message: reason,
          provider_message: nil,
          rate_limit_info: nil,
          retryable: false
        }
    }
  end

  defp process_stream_event({:start, partial}, _partial, context, added, _stream, _config) do
    # Metadata alone is not output. Defer the transcript start until an update
    # or final message so a discarded pre-output attempt leaves no dangling start.
    {:continue, StreamAccumulator.new(partial), context, added}
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
    accumulator = StreamAccumulator.apply(partial || StreamAccumulator.new(), event)

    context =
      if added do
        context
      else
        message = StreamAccumulator.metadata(accumulator)
        EventStream.push!(stream, {:message_start, message})
        %{context | messages: context.messages ++ [message]}
      end

    EventStream.push!(stream, {:message_update, event})
    {:continue, accumulator, context, true}
  end

  defp process_stream_event(
         {:done, _reason, final_message},
         partial,
         context,
         added,
         stream,
         config
       ) do
    final_message = reconcile_final_message(final_message, partial)
    final_message = normalize_terminal_message(final_message)
    Loop.record_budget_usage(config, final_message, stream)

    if final_message.stop_reason == :error do
      {:failed, final_message, context, added}
    else
      {final_message, context} = finalize_message(final_message, context, added, stream, config)
      {:done, final_message, context}
    end
  end

  defp process_stream_event(
         {:error, _reason, final_message},
         partial,
         context,
         added,
         stream,
         config
       ) do
    final_message = reconcile_final_message(final_message, partial)
    final_message = %{final_message | stop_reason: :error}
    Loop.record_budget_usage(config, final_message, stream)
    {:failed, final_message, context, added}
  end

  defp process_stream_event({:canceled, reason}, partial, context, added, stream, config)
       when reason in [:stream_idle_timeout, :dispatcher_stream_idle_timeout] do
    message = partial_snapshot(partial) || build_error_message(config, :error, nil)

    message = %{
      message
      | stop_reason: :error,
        error_message: LemonAi.Error.format_error(reason),
        error_details: LemonAi.Error.to_error_details(reason)
    }

    Loop.record_budget_usage(config, message, stream)
    {:failed, message, context, added}
  end

  defp process_stream_event({:canceled, reason}, partial, context, added, stream, config) do
    {final_message, context} =
      finalize_canceled_message(partial_snapshot(partial), context, added, stream, config, reason)

    {:done, final_message, context}
  end

  defp process_stream_event(_event, partial, context, added, _stream, _config) do
    {:continue, partial, context, added}
  end

  defp accumulate_arguments({:tool_call_delta, index, delta}, arguments)
       when is_binary(delta),
       do: Map.update(arguments, index, [delta], &[delta | &1])

  defp accumulate_arguments(_event, arguments), do: arguments

  defp validate_terminal_arguments({:done, reason, message}, partial, tools, raw) do
    message = reconcile_final_message(message, partial)
    {:done, reason, normalize_arguments(message, tools, raw)}
  end

  defp validate_terminal_arguments(event, _partial, _tools, _raw), do: event

  defp normalize_arguments(%AssistantMessage{stop_reason: reason} = message, tools, raw)
       when reason not in [:error, :aborted, :redirected] do
    calls = Enum.filter(message.content || [], &match?(%ToolCall{}, &1))
    errors = ToolCalls.argument_errors(calls, tools)

    errors =
      Enum.reduce(raw, errors, fn {index, chunks}, errors ->
        raw = chunks |> Enum.reverse() |> IO.iodata_to_binary()

        # Providers stream a no-argument call as "" (Anthropic's first
        # `partial_json`), which means `{}`; a parameterless tool has nothing
        # to decode. Validation of the final arguments still applies.
        cond do
          String.trim(raw) == "" -> errors
          parameterless_call?(Enum.at(message.content || [], index), tools) -> errors
          true -> raw_argument_errors(raw, errors)
        end
      end)

    if errors == [] do
      message
    else
      %{
        message
        | stop_reason: :error,
          error_message: "malformed_tool_arguments",
          error_details: %{
            argument_errors: Enum.join(errors, "; "),
            original_message: message
          }
      }
    end
  end

  defp normalize_arguments(message, _tools, _raw), do: message

  defp raw_argument_errors(raw, errors) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> errors
      {:error, error} -> [Exception.message(error) | errors]
      _ -> ["expected JSON object" | errors]
    end
  end

  defp parameterless_call?(%ToolCall{name: name}, tools) do
    case Enum.find(tools || [], &(&1.name == name)) do
      %{parameters: parameters} when is_map(parameters) ->
        properties = Map.get(parameters, "properties") || Map.get(parameters, :properties)
        properties in [nil, %{}]

      _ ->
        false
    end
  end

  defp parameterless_call?(_block, _tools), do: false

  # Once an update is emitted, later empty partials/terminals cannot uncommit it.
  defp output_event?(event) do
    elem(event, 0) in [
      :text_start,
      :text_delta,
      :text_end,
      :thinking_start,
      :thinking_delta,
      :thinking_end,
      :tool_call_start,
      :tool_call_delta,
      :tool_call_end
    ]
  end

  defp committed_content?(%AssistantMessage{content: content}) when is_list(content) do
    Enum.any?(content, fn
      %{type: :text, text: text} -> is_binary(text) and text != ""
      %{type: :thinking, thinking: thinking} -> is_binary(thinking) and thinking != ""
      %{type: :tool_call} -> true
      _ -> false
    end)
  end

  defp committed_content?(_), do: false

  defp partial_snapshot(nil), do: nil
  defp partial_snapshot(accumulator), do: StreamAccumulator.snapshot(accumulator)

  defp default_stream_fn(model, context, options) do
    LemonAi.stream(model, context, options)
  end

  # LemonAi.EventStream can stop immediately on cancel, which can raise on :take
  # (:noproc, :shutdown, or :normal depending on timing).
  # Wrap the take loop to treat those exits as a canceled terminal event.
  defp ai_events(response_stream, signal) do
    Stream.resource(
      fn -> {:active, response_stream} end,
      fn
        {:halting, _stream} ->
          {:halt, nil}

        {:active, stream} ->
          case safe_ai_take(stream, signal) do
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

  defp safe_ai_take(stream, nil) do
    GenServer.call(stream, :take, :infinity)
  catch
    :exit, {:noproc, _} ->
      {:event, {:canceled, :canceled}}

    :exit, {:normal, _} ->
      {:event, {:canceled, :canceled}}

    :exit, {:shutdown, _} ->
      {:event, {:canceled, :canceled}}
  end

  defp safe_ai_take(stream, signal) do
    request = :gen_server.send_request(stream, :take)
    await_ai_event(stream, signal, request)
  end

  defp await_ai_event(stream, signal, request) do
    cond do
      aborted?(signal) ->
        LemonAi.EventStream.cancel(stream, :aborted)
        _ = :gen_server.receive_response(request, 0)
        {:event, {:canceled, :aborted}}

      redirect_requested?(signal) ->
        LemonAi.EventStream.cancel(stream, :redirected)
        _ = :gen_server.receive_response(request, 0)
        {:event, {:canceled, :redirected}}

      true ->
        receive do
          {:lemon_abort, ^signal, kind} when kind in [:abort, :redirect] ->
            await_ai_event(stream, signal, request)

          {[:alias | ^request], _reply} = response ->
            ai_response(response, request)

          {:DOWN, ^request, :process, _server, _reason} = response ->
            ai_response(response, request)
        end
    end
  end

  defp ai_response(response, request) do
    case :gen_server.check_response(response, request) do
      {:reply, reply} ->
        reply

      {:error, {reason, _server}} when reason in [:noproc, :normal, :shutdown] ->
        {:event, {:canceled, :canceled}}

      {:error, {reason, _server}} ->
        exit(reason)
    end
  end

  defp terminal_ai_event?({:done, _reason, _message}), do: true
  defp terminal_ai_event?({:error, _reason, _message}), do: true
  defp terminal_ai_event?({:canceled, _reason}), do: true
  defp terminal_ai_event?(_event), do: false

  defp reconcile_final_message(%AssistantMessage{content: [_ | _]} = final, _partial),
    do: final

  defp reconcile_final_message(%AssistantMessage{} = final, partial) do
    snapshot = partial_snapshot(partial)

    if snapshot != nil and empty_content?(final.content) and not empty_content?(snapshot.content) do
      %{final | content: snapshot.content}
    else
      final
    end
  end

  defp reconcile_final_message(final, _partial), do: final

  defp empty_content?(nil), do: true
  defp empty_content?([]), do: true
  defp empty_content?(_content), do: false

  defp normalize_terminal_message(%AssistantMessage{stop_reason: stop_reason} = message)
       when stop_reason in [:stop, nil] do
    if not has_tool_call?(message) and not has_visible_text?(message) do
      %{
        message
        | content: [
            %TextContent{
              type: :text,
              text: "The provider returned an empty assistant response."
            }
          ],
          stop_reason: :error,
          error_message: "empty_assistant_response"
      }
    else
      message
    end
  end

  defp normalize_terminal_message(message), do: message

  defp has_tool_call?(%AssistantMessage{content: content}) when is_list(content) do
    Enum.any?(content, &match?(%ToolCall{}, &1))
  end

  defp has_tool_call?(_message), do: false

  defp has_visible_text?(%AssistantMessage{content: content}) when is_list(content) do
    Enum.any?(content, fn
      %TextContent{text: text} when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end)
  end

  defp has_visible_text?(_message), do: false

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp redirect_requested?(signal), do: AbortSignal.redirect_requested?(signal)

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

  @doc false
  def record_system_prompt(context, config, stream) do
    if Map.get(config.hooks, :emit_system_prompt, false),
      do: EventStream.push!(stream, {:system_prompt, context.system_prompt})

    :ok
  end

  defp finalize_message(final_message, context, added, stream, config) do
    context =
      if added do
        update_last_message(context, final_message)
      else
        %{context | messages: context.messages ++ [final_message]}
      end

    if not added do
      EventStream.push!(stream, {:message_start, copy_message(final_message)})
    end

    record_system_prompt(context, config, stream)
    EventStream.push!(stream, {:message_end, final_message})
    {final_message, context}
  end

  defp finalize_canceled_message(partial, context, added, stream, config, reason) do
    stop_reason =
      case reason do
        :aborted -> :aborted
        :canceled -> :aborted
        :user_abort -> :aborted
        :redirected -> :redirected
        _ -> :error
      end

    # A redirect is not an error: the loop continues with a correction, so
    # leave error_message nil to avoid misreporting the run as failed.
    error_message =
      if stop_reason == :redirected, do: nil, else: "Stream canceled: #{inspect(reason)}"

    final_message =
      case partial do
        %AssistantMessage{} = msg ->
          msg = strip_tool_calls(msg)
          %{msg | stop_reason: stop_reason, error_message: error_message}

        _ ->
          build_error_message(config, stop_reason, error_message)
      end

    Loop.record_budget_usage(config, final_message, stream)
    finalize_message(final_message, context, added, stream, config)
  end

  # A canceled response may contain tool calls that will never receive results.
  # Keep all cancellation paths transcript-valid for a later continue.
  defp strip_tool_calls(%AssistantMessage{content: content} = msg) when is_list(content) do
    stripped =
      Enum.reject(content, fn
        %ToolCall{} -> true
        %{type: :tool_call} -> true
        _ -> false
      end)

    stripped =
      if stripped == [] do
        [%TextContent{type: :text, text: ""}]
      else
        stripped
      end

    %{msg | content: stripped}
  end

  defp strip_tool_calls(msg), do: msg

  defp build_error_message(%AgentLoopConfig{} = config, stop_reason, error_text) do
    model = config.model || %{}

    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: ""}],
      api: Map.get(model, :api),
      provider: Map.get(model, :provider),
      model: Map.get(model, :id, ""),
      usage: nil,
      stop_reason: stop_reason,
      error_message: error_text,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp convert_tools_to_llm(agent_tools, intent_tracing) do
    Enum.map(agent_tools, fn %AgentTool{} = tool ->
      %Tool{
        name: tool.name,
        description: tool.description,
        parameters: LemonAgent.ToolIntent.schema(tool.parameters, intent_tracing)
      }
    end)
  end

  defp update_last_message(context, new_message) do
    messages = List.replace_at(context.messages, -1, new_message)
    %{context | messages: messages}
  end

  defp copy_message(%AssistantMessage{} = msg) do
    %{msg | content: msg.content}
  end

  defp copy_message(msg), do: msg
end
