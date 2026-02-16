defmodule AgentCore.Loop.Streaming do
  @moduledoc false

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Types.{AgentLoopConfig, AgentTool}

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    TextContent,
    Tool,
    Usage
  }

  @spec stream_assistant_response(
          AgentCore.Types.AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil,
          EventStream.t()
        ) :: {:ok, AssistantMessage.t(), AgentCore.Types.AgentContext.t()} | {:error, term()}
  def stream_assistant_response(context, config, signal, stream_fn, stream) do
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

  defp convert_tools_to_llm(agent_tools) do
    Enum.map(agent_tools, fn %AgentTool{} = tool ->
      %Tool{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
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
