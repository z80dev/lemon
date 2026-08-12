defmodule CodingAgent.Session.ProviderFallback do
  @moduledoc false

  alias LemonAi.Types.StreamOptions
  alias LemonAgent.ModelRuntime.CredentialHealth
  alias LemonAgent.ModelRuntime.Credentials
  alias LemonAgent.ModelRuntime.SessionPins
  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager

  @type stream_fn ::
          (LemonAi.Types.Model.t(), LemonAi.Types.Context.t(), StreamOptions.t() ->
             {:ok, LemonAi.EventStream.t()} | LemonAi.EventStream.t() | {:error, term()})

  @doc """
  Wrap a stream fn with provider x credential failover.

  Options:

    * `:session_id` - stable session identity used as the pool-rotation scope
      and the `SessionPins` key. Callers pass the persisted session id
      (`SessionManager.header.id`); without it rotation runs under `:global`
      and no pinning happens.
  """
  @spec maybe_wrap(
          stream_fn() | nil,
          LemonAi.Types.Model.t(),
          SettingsManager.t(),
          String.t(),
          keyword()
        ) :: stream_fn() | nil
  def maybe_wrap(stream_fn, model, settings, cwd, opts \\ [])

  def maybe_wrap(stream_fn, model, %SettingsManager{} = settings, cwd, opts) do
    session_scope = Keyword.get(opts, :session_id)

    candidates =
      ModelResolver.runtime_fallback_models(model, settings, session_scope: session_scope)

    if candidates == [] do
      stream_fn
    else
      base_stream_fn = stream_fn || (&LemonAi.stream/3)

      fn primary_model, context, options ->
        stream_with_fallback(
          primary_model,
          candidates,
          context,
          options,
          settings,
          cwd,
          base_stream_fn,
          session_scope
        )
      end
    end
  end

  def maybe_wrap(stream_fn, _model, _settings, _cwd, _opts), do: stream_fn

  defp stream_with_fallback(
         primary_model,
         fallback_models,
         context,
         options,
         settings,
         cwd,
         stream_fn,
         session_scope
       ) do
    {:ok, output_stream} = LemonAi.EventStream.start_link()

    {:ok, task_pid} =
      Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
        candidates =
          [primary_model | fallback_models]
          |> Enum.reject(&is_nil/1)
          |> lead_with_pinned_provider(session_scope)

        ctx = %{
          context: context,
          options: options,
          settings: settings,
          cwd: cwd,
          stream_fn: stream_fn,
          output_stream: output_stream,
          session_scope: session_scope,
          primary_provider: primary_model && primary_model.provider
        }

        run_candidates(candidates, ctx, nil)
      end)

    LemonAi.EventStream.attach_task(output_stream, task_pid)
    {:ok, output_stream}
  end

  defp run_candidates([], ctx, last_error) do
    push_last_error(ctx.output_stream, last_error || {:error, :no_provider_candidates})
  end

  defp run_candidates([model | rest], ctx, _last_error) do
    attempt_credentials(model, credential_entries(model, ctx), rest, ctx)
  end

  defp attempt_credentials(model, [entry | more_entries], rest, ctx) do
    route_options =
      model
      |> ModelResolver.build_stream_options(ctx.settings, clear_api_key(ctx.options), ctx.cwd)
      |> apply_credential_api_key(entry, model, ctx.settings, ctx.options)

    case ctx.stream_fn.(model, ctx.context, route_options) do
      {:ok, response_stream} when is_pid(response_stream) ->
        handle_attempt_stream(response_stream, model, entry, more_entries, rest, ctx)

      response_stream when is_pid(response_stream) ->
        handle_attempt_stream(response_stream, model, entry, more_entries, rest, ctx)

      {:error, reason} ->
        action = record_request_failure(model, entry, reason, ctx)

        if action == :next_credential and more_entries != [] do
          attempt_credentials(model, more_entries, rest, ctx)
        else
          run_candidates(rest, ctx, {:error, reason, model})
        end

      other ->
        run_candidates(rest, ctx, {:invalid_stream, other, model})
    end
  end

  defp handle_attempt_stream(response_stream, model, entry, more_entries, rest, ctx) do
    on_commit = fn -> record_commit(model, entry, ctx) end

    case relay_attempt(response_stream, ctx.output_stream, on_commit) do
      {:fallback, :next_credential, error} ->
        record_stream_failure(model, entry, error, ctx)

        if more_entries != [] do
          attempt_credentials(model, more_entries, rest, ctx)
        else
          run_candidates(rest, ctx, error)
        end

      {:fallback, _next_provider, error} ->
        # :next_provider abandons this provider's remaining credentials.
        record_stream_failure(model, entry, error, ctx)
        run_candidates(rest, ctx, error)

      {:done, _committed?} ->
        :ok
    end
  end

  # Ordered credential attempts for a provider candidate: pool credentials
  # first, the single-credential resolution as the final "default" entry
  # (`Credentials.list_provider_api_keys/3`). The session's pinned credential
  # leads when it targets this provider, cooldown credentials are skipped, and
  # when EVERY credential is cooling down the full list is used anyway - a
  # cooled key beats skipping the provider. With nothing resolvable a single
  # placeholder entry keeps today's ensure_api_key/4 behavior.
  defp credential_entries(model, ctx) do
    provider = model && model.provider

    entries =
      ctx.settings
      |> Credentials.list_provider_api_keys(provider)
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> Map.put(entry, :index, index) end)
      |> lead_with_pinned_ref(provider, ctx.session_scope)

    active =
      Enum.reject(entries, fn entry -> CredentialHealth.in_cooldown?(provider, entry.ref) end)

    case {entries, active} do
      {[], _} -> [%{ref: "default", api_key: nil, index: 0}]
      {entries, []} -> entries
      {_, active} -> active
    end
  end

  defp lead_with_pinned_provider(candidates, session_scope) do
    case SessionPins.get(session_scope) do
      %{provider: pinned} when is_binary(pinned) ->
        case Enum.split_with(candidates, &same_provider?(&1.provider, pinned)) do
          {[], _} -> candidates
          {pinned_matches, others} -> pinned_matches ++ others
        end

      _ ->
        candidates
    end
  end

  defp lead_with_pinned_ref(entries, provider, session_scope) do
    case SessionPins.get(session_scope) do
      %{provider: pinned_provider, credential_ref: pinned_ref} when is_binary(pinned_ref) ->
        if same_provider?(provider, pinned_provider) do
          case Enum.split_with(entries, &(&1.ref == pinned_ref)) do
            {[], _} -> entries
            {pinned_matches, others} -> pinned_matches ++ others
          end
        else
          entries
        end

      _ ->
        entries
    end
  end

  # A commit means this (provider, credential) is serving the turn: clear its
  # failure state, and pin it for the session when it is not the natural
  # primary candidate so later turns lead with it (provider prompt caches are
  # per provider+credential). Committing on the natural primary clears any
  # stale pin. Runs at commit time (first useful event), before the terminal
  # event reaches consumers, so pins are visible as soon as the turn resolves.
  defp record_commit(model, entry, ctx) do
    provider = model && model.provider
    CredentialHealth.record_success(provider, entry.ref)

    if same_provider?(provider, ctx.primary_provider) and entry.index == 0 do
      SessionPins.clear(ctx.session_scope)
    else
      SessionPins.pin(ctx.session_scope, normalize_provider_id(provider), entry.ref)
    end
  end

  defp record_stream_failure(model, entry, {:provider_error, event}, ctx) do
    provider = model && model.provider
    CredentialHealth.record_failure(provider, entry.ref, LemonAi.Error.classify(event))
    maybe_clear_pin(provider, entry, ctx)
  end

  defp record_stream_failure(_model, _entry, _error, _ctx), do: :ok

  # Pre-stream request errors keep their historical semantics - every failure
  # walks the candidate chain - with two additions: credential-specific
  # failures (:next_credential) first advance to the next credential of the
  # SAME provider, and credential/provider failures are recorded into
  # CredentialHealth. :fail/:compact-shaped errors are request problems, not
  # credential problems, so they record nothing.
  defp record_request_failure(model, entry, reason, ctx) do
    action = LemonAi.Error.failover_action(reason)

    if action in [:next_credential, :next_provider] do
      provider = model && model.provider
      CredentialHealth.record_failure(provider, entry.ref, LemonAi.Error.classify(reason))
      maybe_clear_pin(provider, entry, ctx)
    end

    action
  end

  # A failure on the session's pinned candidate invalidates the pin; the
  # eventual committed candidate re-pins.
  defp maybe_clear_pin(provider, entry, ctx) do
    case SessionPins.get(ctx.session_scope) do
      %{provider: pinned_provider, credential_ref: pinned_ref} ->
        if same_provider?(provider, pinned_provider) and entry.ref == pinned_ref do
          SessionPins.clear(ctx.session_scope)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp relay_attempt(response_stream, output_stream, on_commit) do
    response_stream
    |> LemonAi.EventStream.events()
    |> Enum.reduce_while(%{committed: false, buffer: []}, fn event, state ->
      failover_action = if state.committed, do: nil, else: failover_action(event)

      cond do
        failover_action != nil ->
          {:halt, {:fallback, failover_action, {:provider_error, event}}}

        not state.committed and useful_event?(event) ->
          on_commit.()
          Enum.each(state.buffer, &emit_event(output_stream, &1))
          emit_event(output_stream, event)
          {:cont, %{state | committed: true, buffer: []}}

        not state.committed and terminal_event?(event) ->
          Enum.each(state.buffer, &emit_event(output_stream, &1))
          emit_event(output_stream, event)
          {:halt, {:done, false}}

        not state.committed ->
          {:cont, %{state | buffer: state.buffer ++ [event]}}

        terminal_event?(event) ->
          emit_event(output_stream, event)
          {:halt, {:done, true}}

        true ->
          emit_event(output_stream, event)
          {:cont, state}
      end
    end)
    |> case do
      %{committed: false, buffer: []} ->
        LemonAi.EventStream.error(output_stream, error_message(nil, "empty_provider_stream"))
        {:done, false}

      %{committed: false, buffer: buffer} ->
        Enum.each(buffer, &emit_event(output_stream, &1))
        LemonAi.EventStream.error(output_stream, error_message(nil, "provider_stream_closed"))
        {:done, false}

      %{committed: true} ->
        {:done, true}

      other ->
        other
    end
  end

  # Pre-commit stream errors only walk the fallback chain when the failure is
  # credential- or provider-specific (per LemonAi.Error.failover_action/1):
  # :next_credential advances to the next credential of the SAME provider,
  # :next_provider abandons the provider for the next candidate. Errors that
  # return nil here hit the terminal_event? branch instead and are relayed
  # terminally without failover:
  #
  #   - :fail (client errors): the request itself is malformed — every
  #     fallback candidate would reject it the same way.
  #   - :compact (context overflow): no candidate can satisfy an oversized
  #     context; recovery is owned by LemonAi.CompactingClient upstream, which
  #     needs to SEE the error to compact and retry.
  defp failover_action({:error, _reason, _message} = event) do
    case LemonAi.Error.failover_action(event) do
      :next_credential -> :next_credential
      :next_provider -> :next_provider
      _ -> nil
    end
  end

  defp failover_action(_), do: nil

  defp terminal_event?({:done, _reason, _message}), do: true
  defp terminal_event?({:error, _reason, _message}), do: true
  defp terminal_event?({:canceled, _reason}), do: true
  defp terminal_event?(_), do: false

  defp useful_event?({:text_delta, _idx, text, _message}) when is_binary(text),
    do: String.trim(text) != ""

  defp useful_event?({:thinking_delta, _idx, text, _message}) when is_binary(text),
    do: String.trim(text) != ""

  defp useful_event?({:tool_call_start, _idx, _message}), do: true
  defp useful_event?({:tool_call_end, _idx, _tool_call, _message}), do: true
  defp useful_event?(_), do: false

  defp emit_event(output_stream, {:done, _reason, message}),
    do: LemonAi.EventStream.complete(output_stream, message)

  defp emit_event(output_stream, {:error, _reason, message}),
    do: LemonAi.EventStream.error(output_stream, message)

  defp emit_event(output_stream, {:canceled, reason}),
    do: LemonAi.EventStream.cancel(output_stream, reason)

  defp emit_event(output_stream, event), do: LemonAi.EventStream.push(output_stream, event)

  defp push_last_error(output_stream, {:provider_error, {:error, reason, message}}) do
    LemonAi.EventStream.error(output_stream, %{message | stop_reason: reason || :error})
  end

  defp push_last_error(output_stream, {:error, reason, model}) do
    LemonAi.EventStream.error(output_stream, error_message(model, inspect(reason)))
  end

  defp push_last_error(output_stream, {:invalid_stream, other, model}) do
    LemonAi.EventStream.error(
      output_stream,
      error_message(model, "invalid_stream: #{inspect(other)}")
    )
  end

  defp push_last_error(output_stream, reason) do
    LemonAi.EventStream.error(output_stream, error_message(nil, inspect(reason)))
  end

  defp error_message(model, message) do
    %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: [%LemonAi.Types.TextContent{type: :text, text: ""}],
      api: model && model.api,
      provider: model && model.provider,
      model: (model && model.id) || "",
      usage: %LemonAi.Types.Usage{},
      stop_reason: :error,
      error_message: message,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp clear_api_key(%StreamOptions{} = options), do: %{options | api_key: nil}
  defp clear_api_key(options), do: options

  # The credential entry's pre-resolved key wins when the stream options carry
  # none; entries without a key (nothing resolvable) fall through to the
  # historical per-attempt resolution.
  defp apply_credential_api_key(
         %StreamOptions{api_key: api_key} = options,
         _entry,
         _model,
         _settings,
         _original
       )
       when is_binary(api_key) and api_key != "" do
    options
  end

  defp apply_credential_api_key(
         %StreamOptions{} = options,
         %{api_key: api_key},
         _model,
         _settings,
         _original
       )
       when is_binary(api_key) and api_key != "" do
    %{options | api_key: api_key}
  end

  defp apply_credential_api_key(options, _entry, model, settings, original_options) do
    ensure_api_key(options, model, settings, original_options)
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

  defp ensure_api_key(options, _model, _settings, _original), do: options

  defp original_api_key(%StreamOptions{api_key: api_key})
       when is_binary(api_key) and api_key != "",
       do: api_key

  defp original_api_key(_), do: nil

  defp same_provider?(a, b), do: normalize_provider_id(a) == normalize_provider_id(b)

  defp normalize_provider_id(provider) when is_atom(provider) and not is_nil(provider),
    do: provider |> Atom.to_string() |> normalize_provider_id()

  defp normalize_provider_id(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider_id(_), do: nil
end
