defmodule CodingAgent.Session.ProviderFallback do
  @moduledoc false

  alias Ai.Types.StreamOptions
  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager

  @type stream_fn ::
          (Ai.Types.Model.t(), Ai.Types.Context.t(), StreamOptions.t() ->
             {:ok, Ai.EventStream.t()} | Ai.EventStream.t() | {:error, term()})

  @spec maybe_wrap(stream_fn() | nil, Ai.Types.Model.t(), SettingsManager.t(), String.t()) ::
          stream_fn() | nil
  def maybe_wrap(stream_fn, model, %SettingsManager{} = settings, cwd) do
    candidates = ModelResolver.runtime_fallback_models(model, settings)

    if candidates == [] do
      stream_fn
    else
      base_stream_fn = stream_fn || (&Ai.stream/3)

      fn primary_model, context, options ->
        stream_with_fallback(
          primary_model,
          candidates,
          context,
          options,
          settings,
          cwd,
          base_stream_fn
        )
      end
    end
  end

  def maybe_wrap(stream_fn, _model, _settings, _cwd), do: stream_fn

  defp stream_with_fallback(
         primary_model,
         fallback_models,
         context,
         options,
         settings,
         cwd,
         stream_fn
       ) do
    {:ok, output_stream} = Ai.EventStream.start_link()

    {:ok, task_pid} =
      Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
        candidates = [primary_model | fallback_models] |> Enum.reject(&is_nil/1)
        run_candidates(candidates, context, options, settings, cwd, stream_fn, output_stream, nil)
      end)

    Ai.EventStream.attach_task(output_stream, task_pid)
    {:ok, output_stream}
  end

  defp run_candidates(
         [],
         _context,
         _options,
         _settings,
         _cwd,
         _stream_fn,
         output_stream,
         last_error
       ) do
    push_last_error(output_stream, last_error || {:error, :no_provider_candidates})
  end

  defp run_candidates(
         [model | rest],
         context,
         options,
         settings,
         cwd,
         stream_fn,
         output_stream,
         _last_error
       ) do
    route_options =
      model
      |> ModelResolver.build_stream_options(settings, clear_api_key(options), cwd)
      |> ensure_api_key(model, settings, options)

    case stream_fn.(model, context, route_options) do
      {:ok, response_stream} when is_pid(response_stream) ->
        case relay_attempt(response_stream, output_stream) do
          {:fallback, error} ->
            run_candidates(rest, context, options, settings, cwd, stream_fn, output_stream, error)

          :emitted ->
            :ok
        end

      response_stream when is_pid(response_stream) ->
        case relay_attempt(response_stream, output_stream) do
          {:fallback, error} ->
            run_candidates(rest, context, options, settings, cwd, stream_fn, output_stream, error)

          :emitted ->
            :ok
        end

      {:error, reason} ->
        run_candidates(
          rest,
          context,
          options,
          settings,
          cwd,
          stream_fn,
          output_stream,
          {:error, reason, model}
        )

      other ->
        run_candidates(
          rest,
          context,
          options,
          settings,
          cwd,
          stream_fn,
          output_stream,
          {:invalid_stream, other, model}
        )
    end
  end

  defp relay_attempt(response_stream, output_stream) do
    response_stream
    |> Ai.EventStream.events()
    |> Enum.reduce_while(%{committed: false, buffer: []}, fn event, state ->
      cond do
        not state.committed and retryable_error?(event) ->
          {:halt, {:fallback, {:provider_error, event}}}

        not state.committed and useful_event?(event) ->
          Enum.each(state.buffer, &emit_event(output_stream, &1))
          emit_event(output_stream, event)
          {:cont, %{state | committed: true, buffer: []}}

        not state.committed and terminal_event?(event) ->
          Enum.each(state.buffer, &emit_event(output_stream, &1))
          emit_event(output_stream, event)
          {:halt, :emitted}

        not state.committed ->
          {:cont, %{state | buffer: state.buffer ++ [event]}}

        terminal_event?(event) ->
          emit_event(output_stream, event)
          {:halt, :emitted}

        true ->
          emit_event(output_stream, event)
          {:cont, state}
      end
    end)
    |> case do
      %{committed: false, buffer: []} ->
        Ai.EventStream.error(output_stream, error_message(nil, "empty_provider_stream"))
        :emitted

      %{committed: false, buffer: buffer} ->
        Enum.each(buffer, &emit_event(output_stream, &1))
        Ai.EventStream.error(output_stream, error_message(nil, "provider_stream_closed"))
        :emitted

      %{committed: true} ->
        :emitted

      other ->
        other
    end
  end

  defp retryable_error?({:error, _reason, _message}), do: true
  defp retryable_error?(_), do: false

  defp terminal_event?({:done, _reason, _message}), do: true
  defp terminal_event?({:error, _reason, _message}), do: true
  defp terminal_event?({:canceled, _reason}), do: true
  defp terminal_event?(_), do: false

  defp useful_event?({:text_delta, _idx, text, _message}) when is_binary(text),
    do: String.trim(text) != ""

  defp useful_event?({:thinking_delta, _idx, text, _message}) when is_binary(text),
    do: String.trim(text) != ""

  defp useful_event?({:tool_call_start, _idx, _message}), do: true
  defp useful_event?({:tool_call_start, _idx, _tool_call, _message}), do: true
  defp useful_event?({:tool_call_end, _idx, _tool_call, _message}), do: true
  defp useful_event?(_), do: false

  defp emit_event(output_stream, {:done, _reason, message}),
    do: Ai.EventStream.complete(output_stream, message)

  defp emit_event(output_stream, {:error, _reason, message}),
    do: Ai.EventStream.error(output_stream, message)

  defp emit_event(output_stream, {:canceled, reason}),
    do: Ai.EventStream.cancel(output_stream, reason)

  defp emit_event(output_stream, event), do: Ai.EventStream.push(output_stream, event)

  defp push_last_error(output_stream, {:provider_error, {:error, reason, message}}) do
    Ai.EventStream.error(output_stream, %{message | stop_reason: reason || :error})
  end

  defp push_last_error(output_stream, {:error, reason, model}) do
    Ai.EventStream.error(output_stream, error_message(model, inspect(reason)))
  end

  defp push_last_error(output_stream, {:invalid_stream, other, model}) do
    Ai.EventStream.error(output_stream, error_message(model, "invalid_stream: #{inspect(other)}"))
  end

  defp push_last_error(output_stream, reason) do
    Ai.EventStream.error(output_stream, error_message(nil, inspect(reason)))
  end

  defp error_message(model, message) do
    %Ai.Types.AssistantMessage{
      role: :assistant,
      content: [%Ai.Types.TextContent{type: :text, text: ""}],
      api: model && model.api,
      provider: model && model.provider,
      model: (model && model.id) || "",
      usage: %Ai.Types.Usage{},
      stop_reason: :error,
      error_message: message,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp clear_api_key(%StreamOptions{} = options), do: %{options | api_key: nil}
  defp clear_api_key(options), do: options

  defp ensure_api_key(%StreamOptions{api_key: api_key} = options, _model, _settings, _original)
       when is_binary(api_key) and api_key != "" do
    options
  end

  defp ensure_api_key(
         %StreamOptions{} = options,
         model,
         %SettingsManager{} = settings,
         original_options
       ) do
    get_api_key = ModelResolver.build_get_api_key(settings)
    provider = model && model.provider

    resolved =
      get_api_key.(provider) ||
        if(is_atom(provider), do: get_api_key.(Atom.to_string(provider))) ||
        original_api_key(original_options)

    if is_binary(resolved) and resolved != "" do
      %{options | api_key: resolved}
    else
      options
    end
  end

  defp original_api_key(%StreamOptions{api_key: api_key})
       when is_binary(api_key) and api_key != "",
       do: api_key

  defp original_api_key(_), do: nil
end
