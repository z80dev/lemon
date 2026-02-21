defmodule LemonChannels.Adapters.Xmtp.Transport do
  @moduledoc false

  use GenServer

  require Logger

  alias LemonChannels.Adapters.Xmtp.{Bridge, PortServer}
  alias LemonChannels.{BindingResolver, GatewayConfig}
  alias LemonChannels.OutboundPayload
  alias LemonChannels.Types.ChatScope
  alias LemonCore.{InboundMessage, RouterBridge, SessionKey}

  @default_poll_interval_ms 1_500
  @default_connect_timeout_ms 15_000
  @default_require_live true
  @max_inbound_dedupe_entries 2_000
  @max_placeholder_type_len 24
  @max_placeholder_detail_len 80
  @max_placeholder_response_len 220
  @wallet_regex ~r/^(0x)?[0-9a-fA-F]{40}$/

  def start_link(opts) do
    cond do
      not enabled?() ->
        Logger.info("xmtp transport disabled")
        :ignore

      true ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl true
  def init(opts) do
    cfg =
      config()
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    {:ok, port_server} = PortServer.start_link(config: cfg, notify_pid: self())

    Bridge.connect(port_server, cfg)

    poll_interval_ms = poll_interval_ms(cfg)
    connect_timeout_ms = connect_timeout_ms(cfg)
    require_live = require_live?(cfg)
    connect_timer_ref = schedule_connect_timeout(connect_timeout_ms)

    {:ok,
     %{
       port_server: port_server,
       connect_cfg: cfg,
       poll_interval_ms: poll_interval_ms,
       connect_timeout_ms: connect_timeout_ms,
       require_live: require_live,
       connected?: false,
       connection_mode: nil,
       last_connected_at: nil,
       last_error: nil,
       fatal_error: nil,
       poll_timer_ref: nil,
       connect_timer_ref: connect_timer_ref,
       account_id: normalize_account_id(cfg),
       seen_inbound_keys: MapSet.new(),
       seen_inbound_order: :queue.new()
     }}
  rescue
    error ->
      Logger.warning("xmtp transport failed to initialize: #{inspect(error)}")
      {:stop, error}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | poll_timer_ref: nil}

    if ready_for_poll?(state) do
      Bridge.poll(state.port_server)
    end

    state = maybe_schedule_poll(state)
    {:noreply, state}
  end

  def handle_info(:connect_timeout, state) do
    state = %{state | connect_timer_ref: nil}

    if state.connected? do
      {:noreply, state}
    else
      message =
        "xmtp bridge did not connect within #{state.connect_timeout_ms}ms; transport is unavailable"

      log_connection_failure(message, state.require_live)

      Bridge.connect(state.port_server, state.connect_cfg)

      state =
        state
        |> mark_unavailable(%{
          code: "connect_timeout",
          message: message
        })
        |> ensure_connect_timeout()

      {:noreply, state}
    end
  end

  def handle_info({:xmtp_bridge_event, %{} = event}, state) do
    {:noreply, handle_bridge_event(event, state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        enabled?: enabled?(),
        connected?: state.connected?,
        mode: format_mode(state.connection_mode),
        healthy?: healthy?(state),
        require_live: state.require_live,
        connect_timeout_ms: state.connect_timeout_ms,
        poll_interval_ms: state.poll_interval_ms,
        last_connected_at: state.last_connected_at,
        fatal_error: map_error(state.fatal_error),
        last_error: map_error(state.last_error)
      }}, state}
  end

  def handle_call({:deliver, %OutboundPayload{} = payload}, _from, state) do
    if send_available?(state) do
      case outbound_payload(payload) do
        {:ok, outbound} ->
          Bridge.send_message(state.port_server, outbound)
          {:reply, {:ok, outbound}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :xmtp_unavailable}, state}
    end
  end

  def handle_call({:deliver, _payload}, _from, state) do
    {:reply, {:error, :unsupported_payload}, state}
  end

  @spec status() :: {:ok, map()} | {:error, term()}
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(__MODULE__, :status, 2_000)
      _ -> {:error, :not_running}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec enabled?() :: boolean()
  def enabled? do
    GatewayConfig.get(:enable_xmtp, false) == true
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    GatewayConfig.get(:xmtp, %{})
    |> normalize_map()
    |> merge_config(Application.get_env(:lemon_channels, :xmtp, %{}))
  rescue
    _ -> %{}
  end

  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{} = payload) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:deliver, payload}, 5_000)
      _ -> {:error, :xmtp_not_running}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec normalize_inbound_message(map()) :: {:ok, InboundMessage.t()} | {:error, term()}
  def normalize_inbound_message(event) when is_map(event) do
    normalized = normalize_inbound(event)

    case inbound_action(normalized) do
      :ignore -> {:error, :empty_message}
      :placeholder_reply -> {:error, :placeholder_reply}
      :runtime_submit -> {:ok, to_inbound_message(normalized, normalize_account_id(config()))}
    end
  rescue
    error -> {:error, error}
  end

  def normalize_inbound_message(_), do: {:error, :invalid_event}

  @doc false
  def normalize_inbound_for_test(event) when is_map(event), do: normalize_inbound(event)

  @doc false
  def inbound_action_for_test(event) when is_map(event) do
    event
    |> normalize_inbound()
    |> inbound_action()
  end

  @doc false
  def placeholder_response_text_for_test(event) when is_map(event) do
    event
    |> normalize_inbound()
    |> placeholder_response_text()
  end

  @doc false
  def inbound_dedupe_key_for_test(event) when is_map(event) do
    normalized = normalize_inbound(event)
    inbound_dedupe_key(normalized, event)
  end

  @doc false
  def reply_metadata_for_test(event) when is_map(event) do
    event
    |> normalize_inbound()
    |> xmtp_reply_metadata()
  end

  defp handle_bridge_event(%{"type" => "connected"} = event, state) do
    mode = event_mode(event)
    state = cancel_connect_timeout(state)

    state =
      %{
        state
        | connected?: true,
          connection_mode: mode,
          last_connected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          last_error: nil
      }
      |> maybe_clear_fatal_for_live()

    case {mode, state.require_live} do
      {:live, _} ->
        Logger.info("xmtp bridge connected (mode=live): #{inspect(event)}")
        maybe_schedule_poll(state)

      {:mock, false} ->
        Logger.warning("xmtp bridge connected in mock mode: #{inspect(event)}")
        maybe_schedule_poll(state)

      {:mock, true} ->
        message =
          "xmtp bridge connected in mock mode while require_live=true; transport remains unavailable"

        Logger.error("#{message}: #{inspect(event)}")

        state
        |> cancel_poll_timer()
        |> mark_unavailable(%{
          code: "mock_mode",
          message: message,
          details: event
        })

      {:unknown, true} ->
        message =
          "xmtp bridge connected with unknown mode while require_live=true; transport remains unavailable"

        Logger.error("#{message}: #{inspect(event)}")

        state
        |> cancel_poll_timer()
        |> mark_unavailable(%{
          code: "unknown_mode",
          message: message,
          details: event
        })

      {:unknown, false} ->
        Logger.warning("xmtp bridge connected with unknown mode: #{inspect(event)}")
        maybe_schedule_poll(state)
    end
  end

  defp handle_bridge_event(%{"type" => "message"} = event, state) do
    if receive_available?(state) do
      normalized = normalize_inbound(event)
      dedupe_key = inbound_dedupe_key(normalized, event)

      case remember_inbound_key(state, dedupe_key) do
        {:duplicate, state} ->
          Logger.debug(
            "xmtp duplicate inbound ignored: conversation_id=#{normalized.conversation_id} message_id=#{normalized.message_id || "missing"}"
          )

          state

        {:ok, state} ->
          handle_inbound(normalized, state)
      end
    else
      Logger.warning("xmtp inbound ignored because transport is unavailable")
      state
    end
  end

  defp handle_bridge_event(%{"type" => "sent"} = event, state) do
    Logger.debug("xmtp sent event: #{inspect(event)}")
    state
  end

  defp handle_bridge_event(%{"type" => "error"} = event, state) do
    Logger.warning("xmtp bridge error: #{inspect(event)}")

    state =
      state
      |> Map.put(:last_error, normalize_bridge_error(event))
      |> maybe_mark_disconnected_on_bridge_exit(event)
      |> maybe_mark_unavailable_for_live_requirement(event)

    if state.connected? do
      maybe_schedule_poll(state)
    else
      ensure_connect_timeout(state)
    end
  end

  defp handle_bridge_event(_event, state), do: state

  defp handle_inbound(normalized, state) do
    case inbound_action(normalized) do
      :ignore ->
        :ok

      :placeholder_reply ->
        send_placeholder_reply(normalized, state.port_server)

      :runtime_submit ->
        submit_inbound(normalized, state.account_id)
    end

    state
  rescue
    error ->
      Logger.warning("xmtp inbound message rejected: #{inspect(error)}")
      state
  end

  defp submit_inbound(normalized, account_id) when is_map(normalized) do
    scope = %ChatScope{transport: :xmtp, chat_id: normalized.wallet_address, topic_id: nil}
    agent_id = BindingResolver.resolve_agent_id(scope)

    {engine_hint, stripped_prompt} = strip_engine_directive(normalized.prompt)
    engine_id = BindingResolver.resolve_engine(scope, engine_hint, nil)
    queue_mode = BindingResolver.resolve_queue_mode(scope) || :collect
    cwd = BindingResolver.resolve_cwd(scope)

    inbound =
      to_inbound_message(normalized, account_id, %{
        agent_id: agent_id,
        engine_id: engine_id,
        queue_mode: queue_mode,
        cwd: cwd,
        prompt: stripped_prompt
      })

    Logger.info(
      "xmtp inbound routed: conversation_id=#{normalized.conversation_id} sender=#{normalized.wallet_address} agent_id=#{agent_id} engine=#{engine_id || "default"}"
    )

    route_to_router(inbound)
  end

  defp inbound_action(normalized) when is_map(normalized) do
    cond do
      String.trim(normalized.prompt || "") == "" -> :ignore
      normalized.prompt_is_placeholder == true -> :placeholder_reply
      true -> :runtime_submit
    end
  end

  defp send_placeholder_reply(normalized, port_server) do
    payload =
      %{
        "conversation_id" => normalized.conversation_id,
        "wallet_address" => normalized.wallet_address,
        "is_group" => normalized.is_group,
        "group_id" => normalized.group_id,
        "reply_to_message_id" => normalized.message_id,
        "content" => placeholder_response_text(normalized)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Bridge.send_message(port_server, payload)
  end

  defp placeholder_response_text(normalized) do
    base =
      "I can only process text XMTP messages right now. Please send your request as plain text."

    summary =
      normalized
      |> unsupported_summary()
      |> sanitize_placeholder_detail()

    message =
      case summary do
        value when is_binary(value) -> "#{base} (received #{value})"
        _ -> base
      end

    truncate_text(message, @max_placeholder_response_len)
  end

  defp unsupported_summary(%{} = normalized) do
    label = placeholder_type_label(normalized.raw_content_type || normalized.content_type)
    detail = extract_unsupported_detail(normalized.raw_content)

    case sanitize_placeholder_detail(detail) do
      value when is_binary(value) -> "#{label}: #{value}"
      _ -> label
    end
  end

  defp placeholder_type_label(value) do
    value =
      case normalize_blank(value) do
        "unsupported:" <> raw -> raw
        raw when is_binary(raw) -> raw
        _ -> "unknown"
      end

    sanitize_text(value, @max_placeholder_type_len) || "unknown"
  end

  defp extract_unsupported_detail(value) when is_map(value) do
    normalize_blank(fetch_nested(value, ["mime_type"])) ||
      normalize_blank(fetch_nested(value, ["mimeType"])) ||
      normalize_blank(fetch_nested(value, ["filename"])) ||
      normalize_blank(fetch_nested(value, ["url"])) ||
      normalize_blank(fetch_nested(value, ["uri"])) ||
      normalize_blank(fetch_nested(value, ["type"]))
  end

  defp extract_unsupported_detail(value) when is_binary(value), do: normalize_blank(value)
  defp extract_unsupported_detail(_value), do: nil

  defp sanitize_placeholder_detail(value), do: sanitize_text(value, @max_placeholder_detail_len)

  defp sanitize_text(value, max_len)
       when is_binary(value) and is_integer(max_len) and max_len > 3 do
    value
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> normalize_blank()
    |> case do
      text when is_binary(text) -> truncate_text(text, max_len)
      _ -> nil
    end
  end

  defp sanitize_text(_value, _max_len), do: nil

  defp truncate_text(value, max_len)
       when is_binary(value) and is_integer(max_len) and max_len > 3 do
    if String.length(value) <= max_len do
      value
    else
      String.slice(value, 0, max_len - 3) <> "..."
    end
  end

  defp inbound_dedupe_key(normalized, event) do
    conversation_id = normalized.conversation_id || "unknown"

    case normalize_blank(normalized.message_id) do
      message_id when is_binary(message_id) ->
        "conversation:#{conversation_id}:message:#{message_id}"

      _ ->
        sent_at =
          normalize_blank(fetch_nested(event, ["sent_at_ns"])) ||
            normalize_blank(fetch_nested(event, ["sentAtNs"])) ||
            normalize_blank(fetch_nested(event, ["sent_at"])) ||
            normalize_blank(fetch_nested(event, ["sentAt"])) ||
            "unknown_sent_at"

        digest =
          {:fallback, conversation_id, sent_at, normalized.sender_inbox_id,
           normalized.wallet_address, normalized.raw_content_type,
           raw_content_digest(normalized.raw_content)}
          |> :erlang.term_to_binary()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 24)

        "conversation:#{conversation_id}:fallback:#{digest}"
    end
  end

  defp remember_inbound_key(state, dedupe_key) do
    if MapSet.member?(state.seen_inbound_keys, dedupe_key) do
      {:duplicate, state}
    else
      seen_inbound_keys = MapSet.put(state.seen_inbound_keys, dedupe_key)
      seen_inbound_order = :queue.in(dedupe_key, state.seen_inbound_order)

      {seen_inbound_keys, seen_inbound_order} =
        trim_inbound_keys(seen_inbound_keys, seen_inbound_order)

      {:ok,
       %{state | seen_inbound_keys: seen_inbound_keys, seen_inbound_order: seen_inbound_order}}
    end
  end

  defp trim_inbound_keys(seen_inbound_keys, seen_inbound_order) do
    if MapSet.size(seen_inbound_keys) > @max_inbound_dedupe_entries do
      case :queue.out(seen_inbound_order) do
        {{:value, oldest}, rest} ->
          trim_inbound_keys(MapSet.delete(seen_inbound_keys, oldest), rest)

        {:empty, rest} ->
          {seen_inbound_keys, rest}
      end
    else
      {seen_inbound_keys, seen_inbound_order}
    end
  end

  defp raw_content_digest(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  rescue
    _ -> "unhashable_content"
  end

  defp normalize_inbound(event) do
    identifiers = extract_identifiers(event)

    raw_content = fetch_nested(event, ["content"])
    raw_content_type = raw_content_type(event)
    content_type = infer_content_type(event)

    {wallet_address, sender_identity_source} =
      resolve_wallet_and_source(%{
        event: event,
        sender_inbox_id: identifiers.sender_inbox_id,
        conversation_id: identifiers.conversation_id,
        message_id: identifiers.message_id,
        raw_content_type: raw_content_type,
        raw_content: raw_content
      })

    is_group = group_conversation?(event)

    group_id =
      if is_group do
        fetch_nested(event, ["group_id"]) || fetch_nested(event, ["conversation", "group_id"])
      else
        nil
      end

    {prompt, prompt_is_placeholder} = decode_prompt(event, content_type)

    %{
      wallet_address: wallet_address,
      sender_inbox_id: identifiers.sender_inbox_id,
      sender_identity_source: sender_identity_source,
      conversation_id: to_string(identifiers.conversation_id),
      message_id: identifiers.message_id,
      content_type: content_type,
      raw_content_type: raw_content_type,
      raw_content: raw_content,
      prompt: prompt,
      prompt_is_placeholder: prompt_is_placeholder,
      is_group: is_group,
      group_id: normalize_blank(group_id),
      session_key: "xmtp:#{wallet_address}:#{identifiers.conversation_id}",
      timestamp: extract_timestamp(event),
      raw_event: event
    }
  end

  defp extract_identifiers(event) do
    conversation_id =
      fetch_nested(event, ["conversation_id"]) ||
        fetch_nested(event, ["conversation", "id"]) ||
        "unknown"

    conversation_id =
      conversation_id
      |> to_string()
      |> normalize_blank() ||
        "unknown"

    sender_inbox_id =
      fetch_nested(event, ["sender_inbox_id"]) ||
        fetch_nested(event, ["senderInboxId"]) ||
        fetch_nested(event, ["sender", "inbox_id"]) ||
        fetch_nested(event, ["sender", "inboxId"])

    sender_inbox_id = normalize_inbox_id(sender_inbox_id)

    message_id =
      normalize_blank(
        fetch_nested(event, ["message_id"]) ||
          fetch_nested(event, ["id"]) ||
          fetch_nested(event, ["message", "id"])
      )

    %{
      conversation_id: conversation_id,
      sender_inbox_id: sender_inbox_id,
      message_id: message_id
    }
  end

  defp resolve_wallet_and_source(%{} = ctx) do
    wallet_candidate =
      fetch_nested(ctx.event, ["sender_address"]) ||
        fetch_nested(ctx.event, ["sender_wallet"]) ||
        fetch_nested(ctx.event, ["wallet_address"]) ||
        fetch_nested(ctx.event, ["peer_address"])

    case normalize_wallet(wallet_candidate) do
      wallet when is_binary(wallet) ->
        {wallet, "wallet"}

      _ ->
        {stable_identity_wallet(%{
           sender_inbox_id: ctx.sender_inbox_id,
           conversation_id: ctx.conversation_id,
           message_id: ctx.message_id,
           raw_content_type: ctx.raw_content_type,
           raw_content: ctx.raw_content
         }), fallback_identity_source(ctx.sender_inbox_id, ctx.conversation_id)}
    end
  end

  defp decode_prompt(event, "reply") do
    content = fetch_nested(event, ["content"])

    text = extract_text(content) || extract_text(event)

    reference =
      fetch_nested(content, ["reply_to_message_id"]) ||
        fetch_nested(content, ["reference"]) ||
        fetch_nested(event, ["reply_to_message_id"])

    cond do
      is_binary(text) and is_binary(reference) -> {"Reply to #{reference}: #{text}", false}
      is_binary(text) -> {text, false}
      is_binary(reference) -> {"Reply to message #{reference}", false}
      true -> {"Reply message", false}
    end
  end

  defp decode_prompt(event, "reaction") do
    content = fetch_nested(event, ["content"])

    emoji =
      normalize_blank(fetch_nested(content, ["emoji"])) ||
        normalize_blank(fetch_nested(content, ["reaction"])) ||
        normalize_blank(fetch_nested(event, ["emoji"]))

    reference =
      normalize_blank(fetch_nested(content, ["reference"])) ||
        normalize_blank(fetch_nested(content, ["target_message_id"])) ||
        normalize_blank(fetch_nested(event, ["reply_to_message_id"]))

    cond do
      is_binary(emoji) and is_binary(reference) ->
        {"Reaction #{emoji} to message #{reference}", false}

      is_binary(emoji) ->
        {"Reaction #{emoji}", false}

      is_binary(reference) ->
        {"Reaction to message #{reference}", false}

      true ->
        {"Reaction message", false}
    end
  end

  defp decode_prompt(event, "text") do
    prompt =
      extract_text(fetch_nested(event, ["content"])) ||
        normalize_blank(fetch_nested(event, ["text"])) ||
        normalize_blank(fetch_nested(event, ["body"]))

    if is_binary(prompt), do: {prompt, false}, else: unsupported_prompt(event, "text")
  end

  defp decode_prompt(event, content_type) do
    prompt =
      extract_text(fetch_nested(event, ["content"])) ||
        normalize_blank(fetch_nested(event, ["text"])) ||
        normalize_blank(fetch_nested(event, ["body"]))

    if is_binary(prompt), do: {prompt, false}, else: unsupported_prompt(event, content_type)
  end

  defp extract_text(nil), do: nil

  defp extract_text(value) when is_binary(value) do
    normalize_blank(value)
  end

  defp extract_text(value) when is_map(value) do
    normalize_blank(fetch_nested(value, ["text"])) ||
      normalize_blank(fetch_nested(value, ["body"])) ||
      normalize_blank(fetch_nested(value, ["content"])) ||
      normalize_blank(fetch_nested(value, ["prompt"]))
  end

  defp extract_text(_), do: nil

  defp infer_content_type(event) do
    value =
      fetch_nested(event, ["content_type"]) ||
        fetch_nested(event, ["contentType"]) ||
        fetch_nested(event, ["content", "type"]) ||
        fetch_nested(event, ["content", "kind"])

    normalize_content_type(value)
  end

  defp normalize_content_type(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" -> "text"
      String.contains?(normalized, "reply") -> "reply"
      String.contains?(normalized, "reaction") -> "reaction"
      normalized == "text" or String.contains?(normalized, "text") -> "text"
      true -> "unsupported:" <> normalized
    end
  end

  defp normalize_content_type(_), do: "text"

  defp group_conversation?(event) do
    value =
      fetch_nested(event, ["is_group"]) ||
        fetch_nested(event, ["conversation", "is_group"]) ||
        fetch_nested(event, ["conversation_type"])

    truthy?(value) or String.downcase(String.trim(to_string(value || ""))) == "group"
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp normalize_wallet(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      Regex.match?(@wallet_regex, value) ->
        cleaned =
          value
          |> String.downcase()
          |> String.trim_leading("0x")

        "0x" <> cleaned

      true ->
        nil
    end
  end

  defp normalize_wallet(_), do: nil

  defp normalize_inbox_id(value) do
    case normalize_blank(value) do
      normalized when is_binary(normalized) ->
        normalized
        |> String.trim()
        |> String.downcase()
        |> normalize_blank()

      normalized when is_integer(normalized) or is_float(normalized) or is_boolean(normalized) ->
        normalized
        |> to_string()
        |> String.downcase()
        |> normalize_blank()

      _ ->
        nil
    end
  end

  defp fallback_identity_source(sender_inbox_id, _conversation_id)
       when is_binary(sender_inbox_id) do
    "sender_inbox_id"
  end

  defp fallback_identity_source(_sender_inbox_id, conversation_id)
       when is_binary(conversation_id) and conversation_id != "unknown" do
    "conversation_id"
  end

  defp fallback_identity_source(_sender_inbox_id, _conversation_id),
    do: "message_content_fingerprint"

  defp stable_identity_wallet(%{} = context) do
    seed =
      context
      |> fallback_identity_seed()
      |> :erlang.term_to_binary()

    digest =
      :crypto.hash(:sha256, seed)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    "0x" <> digest
  end

  defp fallback_identity_seed(context) do
    sender_inbox_id = normalize_blank(Map.get(context, :sender_inbox_id))
    conversation_id = normalize_blank(Map.get(context, :conversation_id)) || "unknown"
    message_id = normalize_blank(Map.get(context, :message_id))
    raw_content_type = normalize_blank(Map.get(context, :raw_content_type))
    raw_content = Map.get(context, :raw_content)

    cond do
      is_binary(sender_inbox_id) and sender_inbox_id != "" ->
        {:inbox, sender_inbox_id}

      conversation_id != "unknown" ->
        {:conversation, conversation_id}

      true ->
        {:unknown, message_id || "unknown_message", raw_content_type || "unknown_type",
         raw_content_digest(raw_content)}
    end
  end

  defp raw_content_type(event) do
    normalize_blank(fetch_nested(event, ["content_type"])) ||
      normalize_blank(fetch_nested(event, ["contentType"])) ||
      normalize_blank(fetch_nested(event, ["content", "type"])) ||
      normalize_blank(fetch_nested(event, ["content", "kind"]))
  end

  defp extract_timestamp(event) when is_map(event) do
    cond do
      is_integer(fetch_nested(event, ["sent_at"])) ->
        fetch_nested(event, ["sent_at"])

      is_integer(fetch_nested(event, ["sentAt"])) ->
        fetch_nested(event, ["sentAt"])

      is_integer(fetch_nested(event, ["timestamp"])) ->
        fetch_nested(event, ["timestamp"])

      true ->
        sent_at_ns =
          normalize_blank(fetch_nested(event, ["sent_at_ns"])) ||
            normalize_blank(fetch_nested(event, ["sentAtNs"]))

        case parse_integer(sent_at_ns) do
          value when is_integer(value) and value > 0 -> div(value, 1_000_000_000)
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp extract_timestamp(_), do: nil

  defp unsupported_prompt(event, content_type) do
    label = placeholder_type_label(raw_content_type(event) || content_type)

    detail =
      sanitize_placeholder_detail(extract_unsupported_detail(fetch_nested(event, ["content"])))

    prompt =
      case detail do
        value when is_binary(value) ->
          "Non-text XMTP message (#{label}): #{value}. Please send text."

        _ ->
          "Non-text XMTP message (#{label}). Please send text."
      end

    {prompt, true}
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_connect_timeout(timeout_ms) do
    Process.send_after(self(), :connect_timeout, timeout_ms)
  end

  defp maybe_schedule_poll(state) do
    if ready_for_poll?(state) and is_nil(state.poll_timer_ref) do
      %{state | poll_timer_ref: schedule_poll(state.poll_interval_ms)}
    else
      state
    end
  end

  defp ready_for_poll?(state) do
    state.connected? and send_available?(state)
  end

  defp send_available?(state) do
    cond do
      not state.connected? -> false
      not is_nil(state.fatal_error) -> false
      state.connection_mode == :live -> true
      state.require_live -> false
      state.connection_mode in [:mock, :unknown] -> true
      true -> false
    end
  end

  defp receive_available?(state), do: send_available?(state)

  defp connect_timeout_ms(cfg) do
    cfg
    |> fetch_meta(:connect_timeout_ms)
    |> positive_integer_or_default(@default_connect_timeout_ms)
  end

  defp require_live?(cfg) do
    cfg
    |> fetch_meta(:require_live)
    |> normalize_boolean(@default_require_live)
  end

  defp poll_interval_ms(cfg) do
    cfg
    |> fetch_meta(:poll_interval_ms)
    |> positive_integer_or_default(@default_poll_interval_ms)
  end

  defp positive_integer_or_default(value, _default) when is_integer(value) and value > 0,
    do: value

  defp positive_integer_or_default(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer_or_default(_value, default), do: default

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(value, _default) when is_integer(value), do: value != 0

  defp normalize_boolean(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> default
    end
  end

  defp normalize_boolean(_value, default), do: default

  defp map_error(nil), do: nil

  defp map_error(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  defp map_error(value), do: %{detail: inspect(value)}

  defp format_mode(:live), do: "live"
  defp format_mode(:mock), do: "mock"
  defp format_mode(:unknown), do: "unknown"
  defp format_mode(_), do: nil

  defp healthy?(state) do
    send_available?(state) and
      (state.connection_mode == :live or
         (not state.require_live and state.connection_mode in [:mock, :unknown]))
  end

  defp event_mode(event) do
    case fetch_meta(event, :mode) |> normalize_blank() do
      value when is_binary(value) ->
        case String.downcase(value) do
          "live" -> :live
          "mock" -> :mock
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp normalize_bridge_error(event) do
    %{
      code: fetch_meta(event, :code) || "bridge_error",
      message: fetch_meta(event, :message) || "xmtp bridge error",
      details: Map.drop(event, ["type"])
    }
  end

  defp mark_unavailable(state, error_map) when is_map(error_map) do
    state =
      state
      |> Map.put(:last_error, error_map)
      |> ensure_connect_timeout()

    if state.require_live do
      Map.put(state, :fatal_error, error_map)
    else
      state
    end
  end

  defp maybe_clear_fatal_for_live(%{connection_mode: :live} = state) do
    %{state | fatal_error: nil}
  end

  defp maybe_clear_fatal_for_live(state), do: state

  defp maybe_mark_disconnected_on_bridge_exit(state, event) do
    message =
      fetch_meta(event, :message)
      |> normalize_blank()
      |> case do
        value when is_binary(value) -> value
        _ -> nil
      end

    if message == "xmtp bridge exited" do
      state
      |> cancel_poll_timer()
      |> Map.put(:connected?, false)
      |> Map.put(:connection_mode, nil)
    else
      state
    end
  end

  defp maybe_mark_unavailable_for_live_requirement(state, event) do
    code =
      fetch_meta(event, :code)
      |> normalize_blank()
      |> case do
        value when is_binary(value) -> value
        _ -> ""
      end

    message = fetch_meta(event, :message) || "xmtp bridge error"

    if state.require_live and
         code in ["sdk_unavailable", "client_init_failed", "identity_unavailable"] do
      mark_unavailable(state, %{
        code: code,
        message: message,
        details: Map.drop(event, ["type"])
      })
    else
      state
    end
  end

  defp ensure_connect_timeout(%{connect_timer_ref: nil} = state) do
    %{state | connect_timer_ref: schedule_connect_timeout(state.connect_timeout_ms)}
  end

  defp ensure_connect_timeout(state), do: state

  defp cancel_connect_timeout(%{connect_timer_ref: nil} = state), do: state

  defp cancel_connect_timeout(%{connect_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | connect_timer_ref: nil}
  end

  defp cancel_poll_timer(%{poll_timer_ref: nil} = state), do: state

  defp cancel_poll_timer(%{poll_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | poll_timer_ref: nil}
  end

  defp log_connection_failure(message, true), do: Logger.error(message)
  defp log_connection_failure(message, false), do: Logger.warning(message)

  defp maybe_put_group(meta, %{is_group: true} = normalized) do
    Map.put(meta, :group, %{
      id: normalized.group_id || normalized.conversation_id
    })
  end

  defp maybe_put_group(meta, _), do: meta

  defp xmtp_reply_metadata(normalized) do
    %{
      wallet_address: normalized.wallet_address,
      conversation_id: normalized.conversation_id,
      is_group: normalized.is_group,
      group_id: normalized.group_id,
      reply_to_message_id: normalized.message_id
    }
  end

  defp to_inbound_message(normalized, account_id) do
    to_inbound_message(normalized, account_id, %{})
  end

  defp to_inbound_message(normalized, account_id, extra)
       when is_map(normalized) and is_map(extra) do
    account_id = normalize_account_id(account_id)
    peer_kind = if(normalized.is_group == true, do: :group, else: :dm)
    wallet_address = normalized.wallet_address || "0xunknown"
    conversation_id = normalized.conversation_id || "unknown"
    agent_id = normalize_blank(fetch_meta(extra, :agent_id)) || "default"
    prompt = normalize_blank(fetch_meta(extra, :prompt)) || normalized.prompt || ""

    session_key =
      SessionKey.channel_peer(%{
        agent_id: agent_id,
        channel_id: "xmtp",
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: wallet_address,
        thread_id: conversation_id
      })

    xmtp_meta = build_xmtp_meta(normalized)
    meta = build_inbound_meta(agent_id, session_key, extra, normalized, xmtp_meta)

    %InboundMessage{
      channel_id: "xmtp",
      account_id: account_id,
      peer: %{
        kind: peer_kind,
        id: wallet_address,
        thread_id: conversation_id
      },
      sender: %{
        id: wallet_address,
        username: nil,
        display_name: nil
      },
      message: %{
        id: normalized.message_id,
        text: prompt,
        timestamp: normalized.timestamp,
        reply_to_id: nil
      },
      raw: normalized.raw_event || normalized,
      meta: meta
    }
  end

  defp build_xmtp_meta(normalized) do
    %{
      wallet_address: normalized.wallet_address,
      sender_inbox_id: normalized.sender_inbox_id,
      sender_identity_source: normalized.sender_identity_source,
      conversation_id: normalized.conversation_id,
      message_id: normalized.message_id,
      content_type: normalized.content_type,
      raw_content_type: normalized.raw_content_type,
      raw_content: normalized.raw_content,
      prompt_is_placeholder: normalized.prompt_is_placeholder,
      is_group: normalized.is_group,
      session_key: normalized.session_key
    }
    |> maybe_put_group(normalized)
  end

  defp build_inbound_meta(agent_id, session_key, extra, normalized, xmtp_meta) do
    %{
      agent_id: agent_id,
      engine_id: normalize_blank(fetch_meta(extra, :engine_id)),
      queue_mode: fetch_meta(extra, :queue_mode),
      cwd: normalize_blank(fetch_meta(extra, :cwd)),
      session_key: session_key,
      xmtp: xmtp_meta,
      xmtp_reply: xmtp_reply_metadata(normalized)
    }
    |> drop_nil_values()
  end

  defp route_to_router(%InboundMessage{} = inbound) do
    case RouterBridge.handle_inbound(inbound) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "RouterBridge.handle_inbound failed for xmtp inbound (wallet=#{inspect(inbound.peer.id)} conversation=#{inspect(inbound.peer.thread_id)}): " <>
            inspect(other)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to route xmtp inbound message: #{inspect(error)}")
      :ok
  end

  defp strip_engine_directive(text) when is_binary(text) do
    text = String.trim(text)

    case Regex.run(~r{^/(lemon|codex|claude|opencode|pi|echo)\b\s*(.*)$}is, text) do
      [_, engine, rest] -> {String.downcase(engine), String.trim(rest)}
      _ -> {nil, text}
    end
  end

  defp strip_engine_directive(_), do: {nil, ""}

  defp outbound_payload(%OutboundPayload{kind: :text} = payload) do
    text =
      cond do
        is_binary(payload.content) ->
          normalize_blank(payload.content)

        is_map(payload.content) ->
          normalize_blank(fetch_meta(payload.content, :text)) ||
            normalize_blank(fetch_meta(payload.content, :content))

        true ->
          nil
      end

    conversation_id = outbound_conversation_id(payload)

    cond do
      not is_binary(text) ->
        {:error, :empty_content}

      not is_binary(conversation_id) ->
        {:error, :missing_conversation_id}

      true ->
        outbound =
          %{
            "conversation_id" => conversation_id,
            "content" => text
          }
          |> maybe_put_outbound_wallet(payload)
          |> maybe_put_outbound_group(payload)
          |> maybe_put_outbound_request_id(payload)

        {:ok, outbound}
    end
  rescue
    error ->
      {:error, error}
  end

  defp outbound_payload(%OutboundPayload{}), do: {:error, :unsupported_kind}
  defp outbound_payload(_), do: {:error, :unsupported_payload}

  defp outbound_conversation_id(%OutboundPayload{} = payload) do
    meta = payload.meta || %{}

    normalize_blank(fetch_meta(meta, :conversation_id)) ||
      normalize_blank(fetch_meta(payload.peer || %{}, :thread_id)) ||
      fallback_peer_conversation_id(payload.peer || %{})
  end

  defp fallback_peer_conversation_id(peer) when is_map(peer) do
    peer_id = normalize_blank(fetch_meta(peer, :id))

    if is_binary(peer_id) and not is_binary(normalize_wallet(peer_id)) do
      peer_id
    else
      nil
    end
  end

  defp fallback_peer_conversation_id(_), do: nil

  defp maybe_put_outbound_wallet(outbound, %OutboundPayload{} = payload) do
    meta = payload.meta || %{}

    wallet =
      normalize_wallet(fetch_meta(meta, :wallet_address)) ||
        normalize_wallet(fetch_meta(payload.peer || %{}, :id))

    maybe_put(outbound, "wallet_address", wallet)
  end

  defp maybe_put_outbound_group(outbound, %OutboundPayload{} = payload) do
    peer = payload.peer || %{}
    meta = payload.meta || %{}
    kind = fetch_meta(peer, :kind)
    is_group = kind in [:group, "group"]
    group_id = normalize_blank(fetch_meta(meta, :group_id))

    outbound
    |> maybe_put("is_group", is_group)
    |> maybe_put("group_id", group_id)
  end

  defp maybe_put_outbound_request_id(outbound, %OutboundPayload{} = payload) do
    request_id =
      normalize_blank(fetch_meta(payload.meta || %{}, :request_id)) ||
        normalize_blank(fetch_meta(payload.meta || %{}, :run_id))

    maybe_put(outbound, "request_id", request_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_account_id(config) when is_map(config) do
    normalize_blank(fetch_meta(config, :account_id)) || "default"
  end

  defp normalize_account_id(value) when is_binary(value) do
    normalize_blank(value) || "default"
  end

  defp normalize_account_id(_), do: "default"

  defp merge_config(base, nil), do: normalize_map(base)

  defp merge_config(base, cfg) do
    Map.merge(normalize_map(base), normalize_map(cfg))
  end

  defp normalize_map(config) when is_map(config), do: config

  defp normalize_map(config) when is_list(config) do
    if Keyword.keyword?(config), do: Enum.into(config, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp fetch_nested(nil, _keys), do: nil

  defp fetch_nested(value, []) do
    normalize_blank(value) || value
  end

  defp fetch_nested(value, [key | rest]) when is_map(value) do
    next = Map.get(value, key) || Map.get(value, maybe_existing_atom(key))
    fetch_nested(next, rest)
  rescue
    _ -> nil
  end

  defp fetch_nested(_value, _keys), do: nil

  defp maybe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    _ -> nil
  end

  defp maybe_existing_atom(key) when is_atom(key), do: key
  defp maybe_existing_atom(_), do: nil

  defp fetch_meta(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_meta(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, maybe_existing_atom(key))
  end

  defp fetch_meta(_, _), do: nil

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(value), do: value
end
