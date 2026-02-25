defmodule LemonRouter.RunProcess.CompactionTrigger do
  @moduledoc """
  Context-window overflow detection and preemptive compaction triggering.

  Handles extraction of completion event fields (answer, error, usage, resume,
  engine), context-overflow detection, and marking sessions for compaction when
  usage approaches the model's context window limit.
  """

  require Logger

  alias LemonCore.ResumeToken
  alias LemonRouter.ChannelContext

  @default_compaction_reserve_tokens 16_384
  @default_codex_context_window_tokens 400_000
  @default_preemptive_compaction_trigger_ratio 0.9
  @context_overflow_error_markers [
    "context_length_exceeded",
    "context length exceeded",
    "context window",
    "http 413",
    "payload too large",
    "request entity too large",
    "string too long",
    "maximum length",
    "invalid 'input[",
    "input[",
    "上下文长度超过限制",
    "令牌数量超出",
    "输入过长",
    "超出最大长度",
    "上下文窗口已满"
  ]

  # Conservative chars-per-token ratio for fallback estimation (4 chars ~ 1 token).
  @fallback_chars_per_token 4

  # ---- Event field extraction ----

  @spec extract_from_completed_or_payload(LemonCore.Event.t() | term(), atom()) :: term()
  def extract_from_completed_or_payload(%LemonCore.Event{payload: payload}, field)
      when is_map(payload) do
    completed = fetch(payload, :completed)

    value = if is_map(completed), do: fetch(completed, field), else: nil
    if is_nil(value), do: fetch(payload, field), else: value
  end

  def extract_from_completed_or_payload(_, _), do: nil

  @spec extract_completed_answer(LemonCore.Event.t() | term()) :: binary() | nil
  def extract_completed_answer(event), do: extract_from_completed_or_payload(event, :answer)

  @spec extract_completed_resume(LemonCore.Event.t() | term()) :: term()
  def extract_completed_resume(event), do: extract_from_completed_or_payload(event, :resume)

  @spec normalize_resume_token(term()) :: ResumeToken.t() | nil
  def normalize_resume_token(nil), do: nil
  def normalize_resume_token(%ResumeToken{} = tok), do: tok

  def normalize_resume_token(%{engine: engine, value: value})
      when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  def normalize_resume_token(%{"engine" => engine, "value" => value})
      when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  def normalize_resume_token(_), do: nil

  @spec extract_completed_ok_and_error(LemonCore.Event.t() | term()) :: {boolean(), term()}
  def extract_completed_ok_and_error(event) do
    ok = extract_from_completed_or_payload(event, :ok)

    if is_boolean(ok) do
      error = extract_from_completed_or_payload(event, :error)
      {ok, error}
    else
      {true, nil}
    end
  end

  @spec extract_completed_engine(LemonCore.Event.t() | term()) :: binary() | nil
  def extract_completed_engine(event) do
    case extract_from_completed_or_payload(event, :engine) do
      engine when is_binary(engine) and engine != "" -> engine
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec extract_completed_usage(LemonCore.Event.t() | term()) :: map() | nil
  def extract_completed_usage(event) do
    case extract_from_completed_or_payload(event, :usage) do
      usage when is_map(usage) -> usage
      _ -> nil
    end
  end

  @spec usage_input_tokens(map() | term()) :: non_neg_integer() | nil
  def usage_input_tokens(usage) when is_map(usage) do
    {primary_key, primary_tokens} = find_primary_token_count(usage)
    cached_tokens = sum_cached_tokens(usage)
    compute_total_input_tokens(primary_key, primary_tokens, cached_tokens)
  rescue
    _ -> nil
  end

  def usage_input_tokens(_), do: nil

  # Produce a safe, bounded label for introspection error payloads.
  # Avoids leaking raw term dumps, stacktraces, or secrets.
  @spec safe_error_label(term()) :: String.t() | nil
  def safe_error_label(nil), do: nil
  def safe_error_label(err) when is_atom(err), do: Atom.to_string(err)
  def safe_error_label(err) when is_binary(err), do: String.slice(err, 0, 80)

  def safe_error_label(%{__exception__: true} = err),
    do: err.__struct__ |> Module.split() |> Enum.join(".") |> String.slice(0, 80)

  def safe_error_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  def safe_error_label(_), do: "unknown_error"

  @doc false
  @spec estimate_input_tokens_from_prompt(map()) :: non_neg_integer() | nil
  def estimate_input_tokens_from_prompt(state) do
    prompt =
      case Map.get(state, :job) do
        %LemonGateway.Types.Job{prompt: p} when is_binary(p) -> p
        _ -> nil
      end

    if is_binary(prompt) and byte_size(prompt) > 0 do
      div(byte_size(prompt), @fallback_chars_per_token)
    else
      nil
    end
  rescue
    _ -> nil
  end

  @spec context_length_exceeded_error?(term()) :: boolean()
  def context_length_exceeded_error?(err) do
    text =
      cond do
        is_binary(err) ->
          err

        is_atom(err) ->
          Atom.to_string(err)

        true ->
          inspect(err, limit: 200, printable_limit: 8_000)
      end
      |> String.downcase()

    Enum.any?(@context_overflow_error_markers, &String.contains?(text, &1))
  rescue
    _ -> false
  end

  # ---- Compaction marker logic ----

  @spec maybe_reset_resume_on_context_overflow(map(), LemonCore.Event.t() | term()) :: :ok
  def maybe_reset_resume_on_context_overflow(state, %LemonCore.Event{} = event) do
    case extract_completed_ok_and_error(event) do
      {false, err} ->
        if context_length_exceeded_error?(err) do
          Logger.warning(
            "RunProcess context overflow run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
              "error=#{inspect(err)}"
          )

          # Clear generic chat-state resume for all sessions so the next run can start fresh.
          _ = safe_delete_chat_state(state.session_key)

          # Mark a generic pending compaction for any channel type.
          LemonCore.Store.put(:pending_compaction, state.session_key, %{
            reason: "overflow",
            session_key: state.session_key,
            set_at_ms: System.system_time(:millisecond)
          })

          # Telegram-specific: reset resume state and mark Telegram pending compaction.
          reset_telegram_resume_state(state.session_key)
          mark_telegram_pending_compaction(state.session_key, :overflow)
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def maybe_reset_resume_on_context_overflow(_state, _event), do: :ok

  @spec maybe_mark_pending_compaction_near_limit(map(), LemonCore.Event.t() | term()) :: :ok
  def maybe_mark_pending_compaction_near_limit(state, %LemonCore.Event{} = event) do
    with true <- explicit_completed_ok_true?(event),
         cfg <- preemptive_compaction_config(state.session_key),
         true <- cfg.enabled,
         context_window when is_integer(context_window) and context_window > 0 <-
           resolve_preemptive_compaction_context_window(state, event, cfg),
         threshold when is_integer(threshold) and threshold > 0 <-
           preemptive_compaction_threshold(
             context_window,
             cfg.reserve_tokens,
             cfg.trigger_ratio
           ) do
      # Try precise usage first; fall back to char-based estimate.
      usage = extract_completed_usage(event)
      input_tokens = if is_map(usage), do: usage_input_tokens(usage), else: nil

      {effective_tokens, source} =
        if is_integer(input_tokens) and input_tokens > 0 do
          {input_tokens, :usage}
        else
          estimate = estimate_input_tokens_from_prompt(state)

          if is_integer(estimate) and estimate > 0 do
            {estimate, :char_estimate}
          else
            {nil, :none}
          end
        end

      if is_integer(effective_tokens) and effective_tokens >= threshold do
        Logger.warning(
          "RunProcess pending compaction marker run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)} input_tokens=#{effective_tokens} " <>
            "threshold=#{threshold} context_window=#{context_window} source=#{source}"
        )

        compaction_details = %{
          input_tokens: effective_tokens,
          threshold_tokens: threshold,
          context_window_tokens: context_window
        }

        # Generic compaction marker for all session types
        LemonCore.Store.put(:pending_compaction, state.session_key, %{
          reason: "near_limit",
          session_key: state.session_key,
          set_at_ms: System.system_time(:millisecond),
          input_tokens: effective_tokens,
          threshold_tokens: threshold,
          context_window_tokens: context_window,
          token_source: to_string(source)
        })

        # Telegram-specific compaction marker (preserves existing behavior)
        mark_telegram_pending_compaction(
          state.session_key,
          :near_limit,
          compaction_details
        )
      end
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def maybe_mark_pending_compaction_near_limit(_state, _event), do: :ok

  # ---- Private helpers ----

  @primary_token_keys [:input_tokens, :input, :prompt_tokens]
  @cached_token_keys [
    :cached_input_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens
  ]

  defp find_primary_token_count(usage) do
    Enum.find_value(@primary_token_keys, {nil, nil}, fn key ->
      case maybe_parse_positive_int(fetch(usage, key)) do
        value when is_integer(value) -> {key, value}
        _ -> nil
      end
    end)
  end

  defp sum_cached_tokens(usage) do
    Enum.reduce(@cached_token_keys, 0, fn key, acc ->
      case maybe_parse_positive_int(fetch(usage, key)) do
        value when is_integer(value) -> acc + value
        _ -> acc
      end
    end)
  end

  defp compute_total_input_tokens(key, tokens, cached)
       when is_integer(tokens) and key in [:input_tokens, :input],
       do: tokens + cached

  defp compute_total_input_tokens(_key, tokens, _cached) when is_integer(tokens), do: tokens
  defp compute_total_input_tokens(_key, _tokens, cached) when cached > 0, do: cached
  defp compute_total_input_tokens(_key, _tokens, _cached), do: nil

  defp maybe_parse_positive_int(value) when is_integer(value) and value > 0, do: value

  defp maybe_parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp maybe_parse_positive_int(_), do: nil

  defp explicit_completed_ok_true?(%LemonCore.Event{} = event) do
    completed =
      event.payload
      |> fetch(:completed)
      |> case do
        %{} = c -> c
        _ -> %{}
      end

    fetch(completed, :ok) === true
  rescue
    _ -> false
  end

  defp explicit_completed_ok_true?(_), do: false

  defp preemptive_compaction_config(session_key) when is_binary(session_key) do
    channel_cfg =
      case ChannelContext.parse_session_key(session_key) do
        %{channel_id: channel_id} when is_binary(channel_id) and channel_id != "" ->
          try do
            channel_atom = String.to_existing_atom(channel_id)
            LemonChannels.GatewayConfig.get(channel_atom, %{}) || %{}
          rescue
            _ -> %{}
          end

        _ ->
          %{}
      end

    channel_cfg = normalize_map(channel_cfg)
    cfg = fetch(channel_cfg, :compaction) |> normalize_map()

    enabled =
      case fetch(cfg, :enabled) do
        nil -> true
        value -> truthy?(value)
      end

    %{
      enabled: enabled,
      context_window_tokens: positive_int_or(fetch(cfg, :context_window_tokens), nil),
      reserve_tokens:
        positive_int_or(fetch(cfg, :reserve_tokens), default_compaction_reserve_tokens()),
      trigger_ratio:
        compaction_trigger_ratio_or(
          fetch(cfg, :trigger_ratio),
          @default_preemptive_compaction_trigger_ratio
        )
    }
  rescue
    _ ->
      %{
        enabled: true,
        context_window_tokens: nil,
        reserve_tokens: default_compaction_reserve_tokens(),
        trigger_ratio: @default_preemptive_compaction_trigger_ratio
      }
  end

  defp preemptive_compaction_config(_session_key) do
    %{
      enabled: true,
      context_window_tokens: nil,
      reserve_tokens: default_compaction_reserve_tokens(),
      trigger_ratio: @default_preemptive_compaction_trigger_ratio
    }
  rescue
    _ ->
      %{
        enabled: true,
        context_window_tokens: nil,
        reserve_tokens: @default_compaction_reserve_tokens,
        trigger_ratio: @default_preemptive_compaction_trigger_ratio
      }
  end

  defp default_compaction_reserve_tokens do
    case LemonCore.Config.cached() do
      %{agent: agent_cfg} when is_map(agent_cfg) ->
        agent_cfg
        |> fetch(:compaction)
        |> normalize_map()
        |> fetch(:reserve_tokens)
        |> positive_int_or(@default_compaction_reserve_tokens)

      _ ->
        @default_compaction_reserve_tokens
    end
  rescue
    _ -> @default_compaction_reserve_tokens
  end

  defp resolve_preemptive_compaction_context_window(state, event, cfg) when is_map(cfg) do
    cfg.context_window_tokens ||
      resolve_context_window_from_model(state) ||
      resolve_context_window_from_engine(state, event)
  end

  defp resolve_preemptive_compaction_context_window(_state, _event, _cfg), do: nil

  defp resolve_context_window_from_model(state) when is_map(state) do
    model =
      state
      |> Map.get(:job)
      |> case do
        %LemonGateway.Types.Job{meta: meta} when is_map(meta) -> fetch(meta, :model)
        _ -> nil
      end

    model_context_window(model)
  rescue
    _ -> nil
  end

  defp resolve_context_window_from_model(_), do: nil

  defp model_context_window(model) when is_binary(model) do
    model
    |> model_lookup_candidates()
    |> Enum.find_value(fn candidate ->
      if Code.ensure_loaded?(Ai.Models) and function_exported?(Ai.Models, :find_by_id, 1) do
        case Ai.Models.find_by_id(candidate) do
          %{context_window: cw} when is_integer(cw) and cw > 0 -> cw
          _ -> nil
        end
      else
        nil
      end
    end)
  rescue
    _ -> nil
  end

  defp model_context_window(_), do: nil

  defp model_lookup_candidates(model) when is_binary(model) do
    trimmed = String.trim(model)

    after_colon =
      case String.split(trimmed, ":", parts: 2) do
        [_prefix, rest] -> rest
        _ -> nil
      end

    after_slash =
      case String.split(trimmed, "/", parts: 2) do
        [_prefix, rest] -> rest
        _ -> nil
      end

    nested_after_colon_slash =
      case after_colon do
        value when is_binary(value) ->
          case String.split(value, "/", parts: 2) do
            [_prefix, rest] -> rest
            _ -> nil
          end

        _ ->
          nil
      end

    [trimmed, after_colon, after_slash, nested_after_colon_slash]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp model_lookup_candidates(_), do: []

  defp resolve_context_window_from_engine(state, event) do
    engine =
      extract_completed_engine(event) ||
        case Map.get(state, :job) do
          %LemonGateway.Types.Job{} = job ->
            job.engine_id

          _ ->
            nil
        end

    engine_text = String.downcase(to_string(engine || ""))
    if String.contains?(engine_text, "codex"), do: @default_codex_context_window_tokens, else: nil
  rescue
    _ -> nil
  end

  defp preemptive_compaction_threshold(context_window, reserve_tokens, trigger_ratio)
       when is_integer(context_window) and context_window > 0 and is_integer(reserve_tokens) and
              reserve_tokens > 0 and is_float(trigger_ratio) and trigger_ratio > 0.0 do
    reserve_threshold = max(context_window - reserve_tokens, 1)
    ratio_threshold = max(trunc(context_window * trigger_ratio), 1)
    min(reserve_threshold, ratio_threshold)
  end

  defp preemptive_compaction_threshold(_context_window, _reserve_tokens, _trigger_ratio), do: nil

  defp compaction_trigger_ratio_or(value, _default)
       when is_float(value) and value > 0.0 and value <= 1.0 do
    value
  end

  defp compaction_trigger_ratio_or(value, _default)
       when is_integer(value) and value > 0 and value <= 1 do
    value * 1.0
  end

  defp compaction_trigger_ratio_or(value, _default)
       when is_integer(value) and value > 1 and value <= 100 do
    value / 100.0
  end

  defp compaction_trigger_ratio_or(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} when parsed > 0.0 and parsed <= 1.0 ->
        parsed

      {parsed, _} when parsed > 1.0 and parsed <= 100.0 ->
        parsed / 100.0

      _ ->
        default
    end
  end

  defp compaction_trigger_ratio_or(_value, default), do: default

  defp compaction_marker_details(details) when is_map(details) do
    Enum.reduce(details, %{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_atom(key) or is_binary(key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp compaction_marker_details(_), do: %{}

  defp reset_telegram_resume_state(session_key) when is_binary(session_key) do
    with %{kind: :channel_peer, channel_id: "telegram"} = parsed <-
           ChannelContext.parse_session_key(session_key) do
      account_id = normalize_telegram_account_id(parsed)

      chat_id = ChannelContext.parse_int(parsed.peer_id)
      thread_id = ChannelContext.parse_int(parsed.thread_id)

      _ = safe_delete_chat_state(session_key)

      if is_integer(chat_id) do
        _ = safe_delete_selected_resume(account_id, chat_id, thread_id)
        _ = safe_clear_thread_index(:telegram_msg_session, account_id, chat_id, thread_id)
        _ = safe_clear_thread_index(:telegram_msg_resume, account_id, chat_id, thread_id)
      end

      Logger.warning(
        "Reset Telegram resume state after context_length_exceeded for session_key=#{inspect(session_key)}"
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reset_telegram_resume_state(_), do: :ok

  defp mark_telegram_pending_compaction(session_key, reason) when is_binary(session_key) do
    mark_telegram_pending_compaction(session_key, reason, %{})
  end

  defp mark_telegram_pending_compaction(_session_key, _reason), do: :ok

  defp mark_telegram_pending_compaction(session_key, reason, details)
       when is_binary(session_key) and is_map(details) do
    with %{kind: :channel_peer, channel_id: "telegram"} = parsed <-
           ChannelContext.parse_session_key(session_key) do
      account_id = normalize_telegram_account_id(parsed)

      chat_id = ChannelContext.parse_int(parsed.peer_id)
      thread_id = ChannelContext.parse_int(parsed.thread_id)

      if is_integer(chat_id) and Code.ensure_loaded?(LemonCore.Store) and
           function_exported?(LemonCore.Store, :put, 3) do
        payload =
          %{
            reason: to_string(reason || "unknown"),
            session_key: session_key,
            set_at_ms: System.system_time(:millisecond)
          }
          |> Map.merge(compaction_marker_details(details))

        LemonCore.Store.put(
          :telegram_pending_compaction,
          {account_id, chat_id, thread_id},
          payload
        )
      end
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp mark_telegram_pending_compaction(_session_key, _reason, _details), do: :ok

  defp normalize_telegram_account_id(parsed) do
    case parsed.account_id do
      account when is_binary(account) and account != "" -> account
      _ -> "default"
    end
  end

  defp safe_delete_chat_state(key), do: LemonCore.Store.delete_chat_state(key)

  defp safe_delete_selected_resume(account_id, chat_id, thread_id)
       when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.delete(:telegram_selected_resume, {account_id, chat_id, thread_id})

    :ok
  rescue
    _ -> :ok
  end

  defp safe_delete_selected_resume(_account_id, _chat_id, _thread_id), do: :ok

  defp safe_clear_thread_index(table, account_id, chat_id, thread_id)
       when is_atom(table) and is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.list(table)
    |> Enum.each(fn
      {{acc, cid, tid, _msg_id} = key, _value}
      when acc == account_id and cid == chat_id and tid == thread_id ->
        _ = LemonCore.Store.delete(table, key)

      _ ->
        :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp safe_clear_thread_index(_table, _account_id, _chat_id, _thread_id), do: :ok

  # ---- Shared utility helpers ----

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{})
    else
      %{}
    end
  end

  defp normalize_map(_), do: %{}

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp positive_int_or(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int_or(_value, default), do: default
end
