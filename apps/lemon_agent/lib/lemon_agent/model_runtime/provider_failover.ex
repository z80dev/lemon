defmodule LemonAgent.ModelRuntime.ProviderFailover do
  @moduledoc """
  Provider x credential failover for one model request.

  Configure it on `AgentLoopConfig.provider_failover` (or the Agent's
  `:provider_failover` option); the loop wraps its stream function with
  `wrap/3`. Candidates are the request's model, then `provider_routing`
  fallback models and providers (`ModelResolver.runtime_fallback_models/3`),
  each with its ordered credentials (`Credentials.list_provider_api_keys/3`).
  Before any output commits, a credential or provider failure moves to the
  next credential or candidate; a 401 first refreshes the same credential
  once. The first committed output fixes provider, model and credential: it
  is recorded in `CredentialHealth` and pinned in `SessionPins`; failures are
  recorded in `CredentialHealth` and clear a failed pin.

  ## Attempt budget

  The loop owns one attempt budget per response: `max_retries + 1` upstream
  attempts in total (at least two, so disabling retries keeps one failover
  attempt), shared by its own retries and every candidate tried here
  (`:budget` option). A walk stops when the budget is spent and reports the
  last failure, so failover never multiplies the retry budget.

  ## Cost cap

  The loop's `check_model_cost` runs for every candidate before it is tried
  (`:check_model_cost` option); a capped candidate is skipped without an
  upstream attempt.
  """

  alias LemonAgent.ModelRuntime.CredentialHealth
  alias LemonAgent.ModelRuntime.Credentials
  alias LemonAgent.ModelRuntime.ModelResolver
  alias LemonAgent.ModelRuntime.SessionPins
  alias LemonAi.Retry
  alias LemonAi.Types.StreamOptions

  @max_precommit_events 256

  @type stream_fn ::
          (LemonAi.Types.Model.t(), LemonAi.Types.Context.t(), StreamOptions.t() ->
             {:ok, LemonAi.EventStream.t()} | LemonAi.EventStream.t() | {:error, term()})

  @typedoc """
  Failover configuration: resolution `settings` (`t:ModelResolver.settings/0`,
  carrying `providers` and `provider_routing`), the config `cwd`, the stable
  `session_id` scoping pool rotation and `SessionPins` (`nil` rotates under
  `:global` without pinning) and a `refresh_api_key` callback with the
  `Credentials.refresh_provider_api_key/4` contract.
  """
  @type t :: %__MODULE__{
          settings: ModelResolver.settings(),
          cwd: String.t() | nil,
          session_id: term(),
          refresh_api_key: (map(), atom() | String.t(), String.t(), String.t() | nil ->
                              {:ok, String.t()} | {:error, atom()})
        }

  @enforce_keys [:settings]
  defstruct settings: nil,
            cwd: nil,
            session_id: nil,
            refresh_api_key: &Credentials.refresh_provider_api_key/4

  @typedoc "Shared attempt counter and its limit."
  @type budget :: {:atomics.atomics_ref(), pos_integer()}

  @doc """
  Builds failover configuration from a `%LemonCore.Config{}` or resolution
  settings. Options: `:cwd`, `:session_id`, `:refresh_api_key`.
  """
  @spec new(LemonCore.Config.t() | ModelResolver.settings(), keyword()) :: t()
  def new(config_or_settings, opts \\ [])

  def new(%LemonCore.Config{} = config, opts),
    do: new(ModelResolver.settings(config), opts)

  def new(%{providers: _, provider_routing: _} = settings, opts) do
    struct!(
      __MODULE__,
      [settings: settings] ++ Keyword.take(opts, [:cwd, :session_id, :refresh_api_key])
    )
  end

  @doc """
  Wraps `stream_fn` with failover. `nil` failover or disabled routing returns
  `stream_fn` unchanged. Each invocation's primary model owns its options;
  only cross-provider candidates discard owned inputs.

  ## Options

    * `:budget` - `{atomics, max_attempts}`: no candidate starts once the
      counter reaches `max_attempts`. The caller charges each `stream_fn`
      invocation to it. Without a budget the walk is unbounded.
    * `:check_model_cost` - `(model, context, options -> :ok | {:error, reason})`
      checked before each candidate.
  """
  @spec wrap(stream_fn(), t() | nil, keyword()) :: stream_fn()
  def wrap(stream_fn, failover, opts \\ [])

  def wrap(stream_fn, nil, _opts), do: stream_fn

  def wrap(stream_fn, %__MODULE__{} = failover, opts) do
    # Even a single provider/credential needs the wrapper for refresh-on-401.
    if Map.get(failover.settings.provider_routing, :enabled, true) == false do
      stream_fn
    else
      fn primary_model, context, options ->
        candidates =
          ModelResolver.runtime_fallback_models(primary_model, failover.settings,
            session_scope: failover.session_id
          )

        stream_with_fallback(primary_model, candidates, context, options, %{
          settings: failover.settings,
          cwd: failover.cwd,
          stream_fn: stream_fn,
          session_scope: failover.session_id,
          refresh_api_key: failover.refresh_api_key,
          budget: Keyword.get(opts, :budget),
          check_model_cost: Keyword.get(opts, :check_model_cost),
          last_error: nil
        })
      end
    end
  end

  defp stream_with_fallback(primary_model, fallback_models, context, options, base) do
    # The outer stream carries no wall-clock timer: serial provider x
    # credential attempts share one turn, so a fixed deadline would kill a
    # healthy committed fallback just because earlier attempts were slow.
    # Per-attempt liveness is enforced by each inner provider stream's own
    # hard and idle timeouts. Pre-commit timeout terminals walk the candidate
    # chain (see failover_action/1 below).
    {:ok, output_stream} =
      LemonAi.EventStream.start_link(timeout: :infinity, idle_timeout: :infinity)

    task_result =
      LemonCore.TaskSupervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
        candidates =
          [primary_model | fallback_models]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(&model_identity/1)
          |> lead_with_pinned_model(base.session_scope)

        ctx =
          Map.merge(base, %{
            context: context,
            options: options,
            output_stream: output_stream,
            primary_model: primary_model,
            refreshed: %{}
          })

        try do
          run_candidates(candidates, ctx)
        catch
          :throw, {:event_stream_push_failed, _reason} ->
            :ok
        end
      end)

    case task_result do
      {:ok, task_pid} ->
        LemonAi.EventStream.attach_task(output_stream, task_pid)
        {:ok, output_stream}

      {:error, reason} = error ->
        LemonAi.EventStream.cancel(output_stream, reason)
        error
    end
  end

  defp run_candidates([], ctx) do
    push_last_error(ctx.output_stream, ctx.last_error || {:error, :no_provider_candidates})
  end

  defp run_candidates([model | rest], ctx) do
    attempt_credentials(model, credential_entries(model, ctx), rest, ctx)
  end

  defp attempt_credentials(model, [entry | more_entries], rest, ctx) do
    original_options =
      if same_provider?(model.provider, ctx.primary_model.provider),
        do: ctx.options,
        else: LemonAgent.ModelRuntime.StreamOptions.sanitize_for_provider_switch(ctx.options)

    route_options =
      model
      |> ModelResolver.build_stream_options(
        ctx.settings,
        clear_api_key(original_options),
        ctx.cwd
      )
      |> apply_credential_api_key(entry, model, ctx.settings, original_options)
      |> with_alternate_signal(model, more_entries, rest, ctx)

    entry = Map.put(entry, :api_key, route_options.api_key)

    # A capped candidate is skipped before it could spend the budget.
    case check_cost(ctx, model, route_options) do
      {:error, reason} ->
        handle_failure(model, entry, more_entries, rest, ctx, reason, {:error, reason, model})

      :ok ->
        if budget_spent?(ctx.budget),
          do:
            push_last_error(
              ctx.output_stream,
              ctx.last_error || {:error, :attempt_budget_exhausted}
            ),
          else: invoke(model, entry, more_entries, rest, ctx, route_options)
    end
  end

  defp budget_spent?({counter, max_attempts}), do: :atomics.get(counter, 1) >= max_attempts
  defp budget_spent?(nil), do: false

  defp check_cost(%{check_model_cost: check, context: context}, model, options)
       when is_function(check, 3),
       do: check.(model, context, options)

  defp check_cost(_ctx, _model, _options), do: :ok

  defp invoke(model, entry, more_entries, rest, ctx, route_options) do
    case ctx.stream_fn.(model, ctx.context, route_options) do
      {:ok, response_stream} when is_pid(response_stream) ->
        handle_attempt_stream(response_stream, model, entry, more_entries, rest, ctx)

      response_stream when is_pid(response_stream) ->
        handle_attempt_stream(response_stream, model, entry, more_entries, rest, ctx)

      {:error, {:canceled, reason}} ->
        LemonAi.EventStream.cancel(ctx.output_stream, reason)

      {:error, reason} when reason in [:aborted, :redirected] ->
        LemonAi.EventStream.cancel(ctx.output_stream, reason)

      {:error, %LemonAi.Types.AssistantMessage{} = message} ->
        cond do
          message.stop_reason in [:aborted, :redirected] ->
            LemonAi.EventStream.error(ctx.output_stream, message)

          useful_event?({:error, :error, message}) ->
            record_commit(model, entry, ctx)
            LemonAi.EventStream.error(ctx.output_stream, %{message | stop_reason: :error})

          true ->
            handle_failure(
              model,
              entry,
              more_entries,
              rest,
              ctx,
              message,
              {:error, message, model}
            )
        end

      {:error, reason} ->
        handle_failure(model, entry, more_entries, rest, ctx, reason, {:error, reason, model})

      other ->
        push_last_error(ctx.output_stream, {:invalid_stream, other, model})
    end
  end

  defp handle_attempt_stream(response_stream, model, entry, more_entries, rest, ctx) do
    on_commit = fn -> record_commit(model, entry, ctx) end

    case relay_attempt(response_stream, ctx.output_stream, on_commit) do
      {:fallback, _action, {:provider_error, event} = error} ->
        handle_failure(model, entry, more_entries, rest, ctx, event, error)

      {:done, _committed?} ->
        :ok
    end
  end

  defp handle_failure(model, entry, more_entries, rest, ctx, reason, terminal) do
    details = error_details(reason)
    refresh_id = {normalize_provider_id(model.provider), entry.ref}

    refresh? =
      details.status == 401 and details.category == :auth and
        not is_map_key(ctx.refreshed, refresh_id)

    if refresh? do
      ctx = %{ctx | refreshed: Map.put(ctx.refreshed, refresh_id, true)}

      case ctx.refresh_api_key.(ctx.settings, model.provider, entry.ref, entry.api_key) do
        {:ok, fresh_key} ->
          attempt_credentials(model, [%{entry | api_key: fresh_key} | more_entries], rest, ctx)

        {:error, _reason} ->
          advance_after_failure(model, entry, more_entries, rest, ctx, reason, terminal, details)
      end
    else
      advance_after_failure(model, entry, more_entries, rest, ctx, reason, terminal, details)
    end
  end

  defp advance_after_failure(model, entry, more_entries, rest, ctx, reason, terminal, details) do
    action =
      if reason == {:canceled, :timeout},
        do: :next_provider,
        else: LemonAi.Error.failover_action(reason)

    if action in [:next_credential, :next_provider] do
      CredentialHealth.record_failure(model.provider, entry.ref, details.category,
        retry_after_ms: retry_after_hint(reason),
        quota_exhausted: LemonAi.Error.quota_exhausted?(details)
      )

      if details.category == :rate_limit,
        do: report_rate_limit(model, entry, retry_after_hint(reason), ctx)

      maybe_clear_pin(model, entry, ctx)
    end

    ctx = %{ctx | last_error: terminal}

    case action do
      :next_credential when more_entries != [] ->
        attempt_credentials(model, more_entries, rest, ctx)

      action when action in [:next_credential, :next_provider] ->
        run_candidates(rest, ctx)

      _ ->
        push_last_error(ctx.output_stream, terminal)
    end
  end

  # A rate-limited omp-broker account is blocked at the broker until the
  # longer of the local cooldown and the provider's retry-after hint, as a
  # wall-clock deadline. Other credentials are unaffected (no-op).
  defp report_rate_limit(model, entry, retry_after_ms, ctx) do
    remaining =
      case CredentialHealth.cooldown_until(model.provider, entry.ref) do
        nil -> 0
        until_ms -> max(until_ms - System.monotonic_time(:millisecond), 0)
      end

    until_ms = System.system_time(:millisecond) + max(remaining, retry_after_ms || 0)
    Credentials.report_rate_limit(ctx.settings, model.provider, entry.ref, until_ms)
  end

  defp error_details({:error, _reason, message}), do: error_details(message)

  defp error_details(%{error_details: nil, error_message: message}) when is_binary(message),
    do: LemonAi.Error.to_error_details(message)

  defp error_details(reason), do: LemonAi.Error.to_error_details(reason)

  defp retry_after_hint({:error, _reason, message}), do: retry_after_hint(message)
  defp retry_after_hint(error), do: Retry.error_retry_after_ms(error)

  defp with_alternate_signal(options, model, entries, candidates, ctx) do
    healthy? = fn provider, entry ->
      is_binary(entry.api_key) and entry.api_key != "" and
        not CredentialHealth.in_cooldown?(provider, entry.ref)
    end

    available? =
      Enum.any?(entries, &healthy?.(model.provider, &1)) or
        Enum.any?(candidates, fn candidate ->
          Enum.any?(credential_entries(candidate, ctx), &healthy?.(candidate.provider, &1))
        end)

    overrides = Map.put(options.provider_retry || %{}, :alternate_available, available?)
    %{options | provider_retry: overrides}
  end

  # Ordered credential attempts for a provider candidate: pool credentials
  # first, the single-credential resolution as the final "default" entry
  # (`Credentials.list_provider_api_keys/3`). The session's pinned credential
  # leads when it targets this provider, cooldown credentials are skipped, and
  # when EVERY credential is cooling down the full list is used anyway - a
  # cooled key beats skipping the provider. With nothing resolvable a single
  # placeholder entry keeps today's ensure_api_key/4 behavior.
  defp credential_entries(model, ctx) do
    provider = model.provider

    entries =
      ctx.settings
      |> Credentials.list_provider_api_keys(provider)
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> Map.put(entry, :index, index) end)
      |> lead_with_pinned_ref(model, ctx.session_scope)

    active =
      Enum.reject(entries, fn entry -> CredentialHealth.in_cooldown?(provider, entry.ref) end)

    case {entries, active} do
      {[], _} -> [%{ref: "default", api_key: nil, index: 0}]
      {entries, []} -> entries
      {_, active} -> active
    end
  end

  defp lead_with_pinned_model(candidates, session_scope) do
    pin = SessionPins.get(session_scope)

    {matches, others} =
      Enum.split_with(candidates, &SessionPins.matches?(pin, &1.provider, &1.id))

    matches ++ others
  end

  defp lead_with_pinned_ref(entries, model, session_scope) do
    case SessionPins.get(session_scope) do
      %{credential_ref: pinned_ref} = pin when is_binary(pinned_ref) ->
        if SessionPins.matches?(pin, model.provider, model.id) do
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

  # The first committed output fixes provider, model and credential identity.
  # Committing on the natural primary clears stale fallback ordering.
  defp record_commit(model, entry, ctx) do
    provider = model.provider
    CredentialHealth.record_success(provider, entry.ref)

    if model_identity(model) == model_identity(ctx.primary_model) and entry.index == 0 do
      SessionPins.clear(ctx.session_scope)
    else
      SessionPins.pin(ctx.session_scope, normalize_provider_id(provider), entry.ref, model.id)
    end
  end

  # A failure on the session's pinned candidate invalidates the pin; the
  # eventual committed candidate re-pins.
  defp maybe_clear_pin(model, entry, ctx) do
    case SessionPins.get(ctx.session_scope) do
      %{credential_ref: pinned_ref} = pin ->
        if SessionPins.matches?(pin, model.provider, model.id) and entry.ref == pinned_ref do
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
    |> Enum.reduce_while(%{committed: false, buffer: [], buffered_events: 0}, fn event, state ->
      failover_action =
        if state.committed or useful_event?(event), do: nil, else: failover_action(event)

      cond do
        failover_action != nil ->
          {:halt, {:fallback, failover_action, {:provider_error, event}}}

        not state.committed and useful_event?(event) ->
          on_commit.()
          Enum.each(Enum.reverse(state.buffer), &emit_event(output_stream, &1))
          emit_event(output_stream, event)

          if terminal_event?(event),
            do: {:halt, {:done, true}},
            else: {:cont, %{state | committed: true, buffer: []}}

        not state.committed and terminal_event?(event) ->
          Enum.each(Enum.reverse(state.buffer), &emit_event(output_stream, &1))
          emit_event(output_stream, event)
          {:halt, {:done, false}}

        not state.committed and state.buffered_events >= @max_precommit_events ->
          LemonAi.EventStream.cancel(response_stream, :overflow)

          LemonAi.EventStream.error(
            output_stream,
            error_message(nil, "provider_event_buffer_overflow")
          )

          {:halt, {:done, false}}

        not state.committed ->
          {:cont,
           %{state | buffer: [event | state.buffer], buffered_events: state.buffered_events + 1}}

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
        Enum.each(Enum.reverse(buffer), &emit_event(output_stream, &1))
        LemonAi.EventStream.error(output_stream, error_message(nil, "provider_stream_closed"))
        {:done, false}

      %{committed: true} ->
        {:done, true}

      other ->
        other
    end
  catch
    :throw, {:event_stream_push_failed, reason} = failure ->
      LemonAi.EventStream.cancel(response_stream, reason)
      throw(failure)
  end

  # Only pre-commit credential/provider errors and provider stream timeouts
  # permit replay. Request errors and context overflow surface to the session.
  defp failover_action({:error, reason, _message}) when reason in [:aborted, :redirected],
    do: nil

  defp failover_action({:error, _, %{stop_reason: reason}})
       when reason in [:aborted, :redirected],
       do: nil

  defp failover_action({:error, _reason, _message} = event) do
    case LemonAi.Error.failover_action(event) do
      :next_credential -> :next_credential
      :next_provider -> :next_provider
      _ -> nil
    end
  end

  # Caller abort/redirect and other cancellation reasons remain terminal.
  defp failover_action({:canceled, :timeout}), do: :next_provider

  defp failover_action(_), do: nil

  defp terminal_event?({:done, _reason, _message}), do: true
  defp terminal_event?({:error, _reason, _message}), do: true
  defp terminal_event?({:canceled, _reason}), do: true
  defp terminal_event?(_), do: false

  defp useful_event?({:text_delta, _idx, text}) when is_binary(text),
    do: text != ""

  defp useful_event?({:thinking_delta, _idx, text}) when is_binary(text),
    do: text != ""

  defp useful_event?({:tool_call_start, _idx, _tool_call}), do: true
  defp useful_event?({:tool_call_end, _idx, _tool_call}), do: true
  defp useful_event?({:tool_call_delta, _idx, _delta}), do: true

  defp useful_event?({kind, _reason, %{content: content}}) when kind in [:done, :error],
    do: Enum.any?(content, &nonempty_content?/1)

  defp useful_event?(_), do: false

  defp nonempty_content?(%{type: :text, text: text}), do: text != ""
  defp nonempty_content?(%{type: :thinking, thinking: text}), do: text != ""
  defp nonempty_content?(_), do: true

  defp emit_event(output_stream, {:done, _reason, message}),
    do: LemonAi.EventStream.complete(output_stream, message)

  defp emit_event(output_stream, {:error, _reason, message}),
    do: LemonAi.EventStream.error(output_stream, message)

  defp emit_event(output_stream, {:canceled, reason}),
    do: LemonAi.EventStream.cancel(output_stream, reason)

  defp emit_event(output_stream, event), do: LemonAi.EventStream.push!(output_stream, event)

  defp push_last_error(output_stream, {:provider_error, {:error, reason, message}}) do
    LemonAi.EventStream.error(output_stream, %{message | stop_reason: reason || :error})
  end

  defp push_last_error(output_stream, {:provider_error, {:canceled, reason}}),
    do: LemonAi.EventStream.cancel(output_stream, reason)

  defp push_last_error(output_stream, {:error, reason, model}) do
    details = error_details(reason)

    details =
      if reason == :model_routing_cost_cap,
        do: Map.put(details, :provider_invoked, false),
        else: details

    message = error_message(model, details.message)
    LemonAi.EventStream.error(output_stream, %{message | error_details: details})
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
  defp clear_api_key(options) when is_map(options), do: Map.put(options, :api_key, nil)
  defp clear_api_key(options), do: options

  # The credential entry's pre-resolved key wins when the stream options carry
  # none; entries without a key (nothing resolvable) fall through to the
  # historical per-attempt resolution.

  defp apply_credential_api_key(
         %StreamOptions{} = options,
         %{api_key: api_key},
         _model,
         _settings,
         _original
       )
       when is_binary(api_key) and api_key != "" do
    provider_options =
      Map.new(options.provider_options, fn {provider, config} ->
        {provider, replace_resolved_api_key(config, api_key)}
      end)

    %{options | api_key: api_key, provider_options: provider_options}
  end

  defp apply_credential_api_key(options, _entry, model, settings, original_options) do
    ensure_api_key(options, model, settings, original_options)
  end

  defp replace_resolved_api_key(%{api_key: _} = config, api_key),
    do: %{config | api_key: api_key}

  defp replace_resolved_api_key(%{"api_key" => _} = config, api_key),
    do: %{config | "api_key" => api_key}

  defp replace_resolved_api_key(config, _api_key), do: config

  defp ensure_api_key(
         %StreamOptions{} = options,
         model,
         %{providers: _} = settings,
         original_options
       ) do
    get_api_key = ModelResolver.build_get_api_key(settings)
    provider = model.provider

    resolved =
      get_api_key.(provider) ||
        if(is_atom(provider), do: get_api_key.(Atom.to_string(provider))) ||
        original_api_key(original_options)

    # An empty key explicitly refuses authentication; nil would let providers
    # fall back to ambient credentials (for example Codex's environment tokens).
    if is_binary(resolved) do
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
  defp model_identity(model), do: {normalize_provider_id(model.provider), model.id}

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
