defmodule LemonChannels.Adapters.WhatsApp.Transport do
  @moduledoc false

  use GenServer

  require Logger

  alias LemonChannels.Adapters.WhatsApp.{
    AccessControl,
    Bridge,
    Dedupe,
    Inbound,
    ModelPolicyAdapter,
    PortServer
  }

  alias LemonChannels.Adapters.WhatsApp.Transport.{
    CommandRouter,
    MessageBuffer,
    SessionRouting
  }

  alias LemonChannels.{BindingResolver, GatewayConfig}
  alias LemonCore.ChatScope
  alias LemonCore.{InboundMessage, RouterBridge}

  @default_debounce_ms 1_500
  @reconnect_initial_ms 2_000
  @reconnect_max_ms 30_000
  @reconnect_factor 1.8
  @reconnect_jitter 0.25
  @reconnect_max_attempts 12
  @command_timeout_ms 30_000

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      Logger.info("whatsapp transport disabled")
      :ignore
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    GatewayConfig.get(:enable_whatsapp, false) == true
  rescue
    _ -> false
  end

  @spec deliver(map()) :: {:ok, term()} | {:error, term()}
  def deliver(payload) when is_map(payload) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:deliver, payload}, @command_timeout_ms + 5_000)

      _ ->
        {:error, :whatsapp_not_running}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  # ============================================================================
  # GenServer init
  # ============================================================================

  @impl true
  def init(opts) do
    cfg =
      GatewayConfig.get(:whatsapp, %{})
      |> normalize_map()
      |> merge_opts(opts)

    account_id = cfg_get(cfg, :account_id, "default")

    :ok = Dedupe.init()
    ModelPolicyAdapter.ensure_session_table()

    {:ok, port_server} = PortServer.start_link(config: cfg, notify_pid: self())

    Bridge.connect(port_server, cfg)

    debounce_ms = cfg_get(cfg, :debounce_ms, @default_debounce_ms)

    state = %{
      port_server: port_server,
      config: cfg,
      account_id: account_id,
      connected?: false,
      own_jid: nil,
      phone_number: nil,
      reconnect_attempts: 0,
      reconnect_timer: nil,
      connected_at: nil,
      buffers: %{},
      debounce_ms: debounce_ms,
      pending_commands: %{},
      pending_new: %{},
      generation: 0
    }

    {:ok, state}
  rescue
    error ->
      Logger.warning("whatsapp transport failed to initialize: #{inspect(error)}")
      {:stop, error}
  end

  # ============================================================================
  # Bridge events
  # ============================================================================

  @impl true
  def handle_info({:whatsapp_bridge_event, %{"type" => "connected"} = event}, state) do
    own_jid = event["jid"]
    phone = event["phone"] || phone_from_jid(own_jid)

    Logger.info(
      "whatsapp bridge connected: own_jid=#{inspect(own_jid)} phone=#{inspect(phone)}"
    )

    state = %{
      state
      | connected?: true,
        own_jid: own_jid,
        phone_number: phone,
        reconnect_attempts: 0,
        reconnect_timer: cancel_timer(state.reconnect_timer),
        connected_at: System.monotonic_time(:millisecond)
    }

    {:noreply, state}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "qr"} = event}, state) do
    Logger.info("whatsapp QR code ready: scan with your phone. data=#{inspect(event["data"])}")
    {:noreply, state}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "pairing_code"} = event}, state) do
    Logger.info("whatsapp pairing code: #{inspect(event["code"])}")
    {:noreply, state}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "connecting"}}, state) do
    Logger.info("whatsapp bridge connecting...")
    {:noreply, %{state | connected?: false}}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "disconnected"} = event}, state) do
    status = event["status_code"]
    is_logged_out = event["is_logged_out"] || false

    state = %{state | connected?: false, own_jid: nil}

    cond do
      is_logged_out or status == 401 ->
        Logger.error(
          "whatsapp logged out (status=#{status}); not reconnecting — re-link required"
        )

        {:noreply, state}

      status == 440 ->
        Logger.error(
          "whatsapp connection replaced (status=440); not reconnecting — another client is active"
        )

        {:noreply, state}

      true ->
        Logger.warning("whatsapp disconnected (status=#{inspect(status)}); scheduling reconnect")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "message"} = event}, state) do
    {:noreply, handle_inbound_event(event, state)}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "reaction"} = event}, state) do
    Logger.debug("whatsapp reaction event: #{inspect(event)}")
    {:noreply, state}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "command_result"} = event}, state) do
    {:noreply, handle_command_result(event, state)}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => "command_error"} = event}, state) do
    {:noreply, handle_command_error(event, state)}
  end

  def handle_info({:whatsapp_bridge_event, %{"type" => type} = event}, state) do
    Logger.debug("whatsapp unhandled bridge event type=#{type}: #{inspect(event)}")
    {:noreply, state}
  end

  def handle_info({:whatsapp_bridge_event, event}, state) do
    Logger.debug("whatsapp unhandled bridge event (no type): #{inspect(event)}")
    {:noreply, state}
  end

  # ============================================================================
  # Debounce flush
  # ============================================================================

  def handle_info({:debounce_flush, key, debounce_ref}, state) do
    case Map.get(state.buffers, key) do
      %{debounce_ref: ^debounce_ref} = buffer ->
        state = %{state | buffers: Map.delete(state.buffers, key)}
        submit_fn = fn inbound -> do_submit_inbound(inbound, state) end
        MessageBuffer.submit_buffer(buffer, submit_fn)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # ============================================================================
  # Reconnect
  # ============================================================================

  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}

    Logger.info(
      "whatsapp reconnecting (attempt #{state.reconnect_attempts}/#{@reconnect_max_attempts})"
    )

    Bridge.connect(state.port_server, state.config)
    {:noreply, state}
  end

  # ============================================================================
  # Command timeout
  # ============================================================================

  def handle_info({:command_timeout, correlation_id}, state) do
    case Map.pop(state.pending_commands, correlation_id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer_ref}, pending_commands} ->
        Logger.warning("whatsapp command timed out: correlation_id=#{correlation_id}")
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_commands: pending_commands}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # handle_call — deliver
  # ============================================================================

  @impl true
  def handle_call({:deliver, payload}, from, state) do
    if state.connected? do
      correlation_id = generate_correlation_id()
      timer_ref = Process.send_after(self(), {:command_timeout, correlation_id}, @command_timeout_ms)

      result = dispatch_outbound(state.port_server, payload, correlation_id)

      case result do
        :ok ->
          pending = Map.put(state.pending_commands, correlation_id, {from, timer_ref})
          {:noreply, %{state | pending_commands: pending}}

        {:error, _} = err ->
          Process.cancel_timer(timer_ref)
          {:reply, err, state}
      end
    else
      {:reply, {:error, :whatsapp_not_connected}, state}
    end
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}

  # ============================================================================
  # Private — inbound pipeline
  # ============================================================================

  defp handle_inbound_event(event, state) do
    jid = event["jid"]
    message_id = event["message_id"]

    cond do
      not state.connected? ->
        Logger.warning("whatsapp inbound ignored: not connected")
        state

      not AccessControl.allowed?(access_config(state), jid, event) ->
        Logger.debug("whatsapp inbound blocked by access control: jid=#{inspect(jid)}")
        state

      Dedupe.seen?(jid, message_id) ->
        Logger.debug("whatsapp duplicate inbound ignored: jid=#{jid} message_id=#{message_id}")
        state

      true ->
        Dedupe.mark(jid, message_id)

        case Inbound.normalize(event) do
          {:ok, inbound} ->
            callbacks = build_callbacks(state)
            CommandRouter.handle_inbound_message(state, inbound, callbacks)

          {:error, reason} ->
            Logger.debug(
              "whatsapp inbound normalize failed: reason=#{inspect(reason)} jid=#{inspect(jid)}"
            )

            state
        end
    end
  rescue
    e ->
      Logger.warning(
        "whatsapp inbound pipeline crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      state
  end

  defp build_callbacks(state) do
    %{
      handle_new_session: fn state, inbound, _args ->
        state = MessageBuffer.drop_buffer_for(state, inbound)
        peer_id = inbound.peer.id
        thread_id = inbound.peer.thread_id
        scope_key = {peer_id, thread_id}

        pending_new =
          Map.put(state.pending_new, scope_key, %{
            peer_id: peer_id,
            thread_id: thread_id
          })

        inbound =
          SessionRouting.maybe_mark_new_session_pending(
            pending_new,
            peer_id,
            thread_id,
            inbound
          )

        state = %{state | pending_new: pending_new}
        do_submit_inbound(inbound, state)
        state
      end,
      handle_model_command: fn state, inbound ->
        text = inbound.message.text || ""
        peer_id = inbound.peer.id
        thread_id = inbound.peer.thread_id
        model_name = String.trim(text |> String.replace(~r/^\/model\s*/i, ""))

        if model_name != "" do
          ModelPolicyAdapter.put_default_model_preference(
            state.account_id,
            peer_id,
            thread_id,
            model_name
          )

          Logger.info("whatsapp model set: peer=#{peer_id} model=#{model_name}")
        end

        state
      end,
      handle_thinking_command: fn state, inbound ->
        text = inbound.message.text || ""
        peer_id = inbound.peer.id
        thread_id = inbound.peer.thread_id
        level = String.trim(text |> String.replace(~r/^\/thinking\s*/i, ""))

        if level != "" do
          ModelPolicyAdapter.put_default_thinking_preference(
            state.account_id,
            peer_id,
            thread_id,
            level
          )

          Logger.info("whatsapp thinking set: peer=#{peer_id} level=#{level}")
        end

        state
      end,
      maybe_cancel_by_reply: fn cb_state, inbound ->
        peer_id = inbound.peer.id
        scope = %ChatScope{transport: :whatsapp, chat_id: peer_id, topic_id: nil}
        session_key = SessionRouting.build_session_key(cb_state.account_id, inbound, scope)

        if is_binary(session_key) and session_key != "" do
          RouterBridge.abort_session(session_key, :user_requested)
        end
      end,
      maybe_mark_new_session_pending: fn state, inbound ->
        peer_id = inbound.peer.id
        thread_id = inbound.peer.thread_id

        SessionRouting.maybe_mark_new_session_pending(
          state.pending_new,
          peer_id,
          thread_id,
          inbound
        )
      end,
      maybe_mark_fork_when_busy: fn state, inbound ->
        peer_id = inbound.peer.id
        thread_id = inbound.peer.thread_id
        SessionRouting.maybe_mark_fork_when_busy(state.account_id, inbound, peer_id, thread_id)
      end,
      should_ignore_for_mention_gate?: fn state, inbound, _text ->
        jid = inbound.peer.id
        event = inbound.raw || %{}
        cfg = access_config(state)
        AccessControl.mention_gated?(cfg, jid, event)
      end,
      maybe_transcribe_voice: fn cb_state, inbound ->
        do_maybe_transcribe_voice(cb_state, inbound)
      end,
      submit_inbound_now: fn state, inbound ->
        do_submit_inbound(inbound, state)
        state
      end
    }
  end

  defp do_submit_inbound(%InboundMessage{} = inbound, state) do
    peer_id = inbound.peer.id
    thread_id = inbound.peer.thread_id

    scope = %ChatScope{transport: :whatsapp, chat_id: peer_id, topic_id: thread_id}
    session_key = SessionRouting.build_session_key(state.account_id, inbound, scope)

    agent_id = BindingResolver.resolve_agent_id(scope)
    engine_id = BindingResolver.resolve_engine(scope, nil, nil)
    queue_mode = BindingResolver.resolve_queue_mode(scope) || :collect
    cwd = BindingResolver.resolve_cwd(scope)

    {model_hint, model_source} =
      ModelPolicyAdapter.resolve_model_hint(
        state.account_id,
        session_key,
        peer_id,
        thread_id
      )

    {thinking_hint, _thinking_source} =
      ModelPolicyAdapter.resolve_thinking_hint(state.account_id, peer_id, thread_id)

    inbound =
      inbound
      |> put_in([Access.key!(:account_id)], state.account_id)
      |> put_in([Access.key!(:meta)], Map.merge(inbound.meta || %{}, %{
          agent_id: agent_id,
          engine_id: engine_id,
          queue_mode: queue_mode,
          cwd: cwd,
          model_hint: model_hint,
          model_hint_source: model_source,
          thinking_hint: thinking_hint
        }))

    Logger.info(
      "whatsapp inbound routing: peer=#{peer_id} session_key=#{inspect(session_key)} " <>
        "agent=#{agent_id} engine=#{engine_id || "default"}"
    )

    # Send typing indicator
    Bridge.typing(state.port_server, peer_id, true)

    RouterBridge.handle_inbound(inbound)
  rescue
    e ->
      Logger.warning(
        "whatsapp submit_inbound failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end

  # ============================================================================
  # Private — voice transcription
  # ============================================================================

  defp do_maybe_transcribe_voice(state, inbound) do
    media_path = inbound.meta[:media_path]
    media_mime = inbound.meta[:media_mime] || "audio/ogg"
    voice_cfg = voice_config(state.config)

    cond do
      not is_binary(media_path) or not File.exists?(media_path) ->
        # No media file — submit as-is
        do_submit_inbound(inbound, state)
        state

      not voice_cfg.enabled ->
        Logger.debug("whatsapp voice transcription disabled; dropping voice note")
        state

      not is_binary(voice_cfg.api_key) or voice_cfg.api_key == "" ->
        Logger.warning("whatsapp voice transcription requires an API key")
        state

      true ->
        # Async transcription under the Task.Supervisor
        Task.Supervisor.start_child(
          LemonChannels.Adapters.WhatsApp.AsyncSupervisor,
          fn ->
            case do_transcribe_voice(media_path, media_mime, voice_cfg) do
              {:ok, transcript} when is_binary(transcript) and transcript != "" ->
                message = Map.put(inbound.message, :text, String.trim(transcript))
                meta = Map.put(inbound.meta || %{}, :voice_transcribed, true)
                updated = %{inbound | message: message, meta: meta}
                do_submit_inbound(updated, state)

              {:ok, _} ->
                Logger.warning("whatsapp voice transcription returned empty text")
                do_submit_inbound(inbound, state)

              {:error, reason} ->
                Logger.warning("whatsapp voice transcription failed: #{inspect(reason)}")
                do_submit_inbound(inbound, state)
            end
          end
        )

        state
    end
  rescue
    e ->
      Logger.warning(
        "whatsapp voice transcription crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      state
  end

  defp do_transcribe_voice(media_path, media_mime, voice_cfg) do
    audio_bytes = File.read!(media_path)

    max_bytes = voice_cfg.max_bytes

    if is_integer(max_bytes) and byte_size(audio_bytes) > max_bytes do
      {:error, :voice_too_large}
    else
      LemonChannels.Adapters.Telegram.VoiceTranscriber.transcribe(%{
        model: voice_cfg.model,
        base_url: voice_cfg.base_url,
        api_key: voice_cfg.api_key,
        audio_bytes: audio_bytes,
        mime_type: media_mime
      })
    end
  end

  defp voice_config(cfg) do
    openai_cfg = LemonCore.Config.cached()[:openai] || %{}

    %{
      enabled: cfg_get(cfg, :voice_transcription, false) == true,
      model: cfg_get(cfg, :voice_transcription_model, "gpt-4o-mini-transcribe"),
      base_url:
        normalize_blank(cfg_get(cfg, :voice_transcription_base_url, nil)) ||
          normalize_blank(openai_cfg[:base_url] || openai_cfg["base_url"]) ||
          "https://api.openai.com/v1",
      api_key:
        normalize_blank(cfg_get(cfg, :voice_transcription_api_key, nil)) ||
          normalize_blank(openai_cfg[:api_key] || openai_cfg["api_key"]),
      max_bytes: cfg_get(cfg, :voice_max_bytes, 10 * 1024 * 1024)
    }
  rescue
    _ ->
      %{enabled: false, model: "gpt-4o-mini-transcribe", base_url: nil, api_key: nil, max_bytes: 10 * 1024 * 1024}
  end

  defp normalize_blank(nil), do: nil
  defp normalize_blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp normalize_blank(_), do: nil

  # ============================================================================
  # Private — command result handling
  # ============================================================================

  defp handle_command_result(%{"id" => correlation_id} = _event, state) do
    case Map.pop(state.pending_commands, correlation_id) do
      {nil, _} ->
        state

      {{from, timer_ref}, pending_commands} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:ok, :sent})
        %{state | pending_commands: pending_commands}
    end
  end

  defp handle_command_result(_event, state), do: state

  defp handle_command_error(%{"id" => correlation_id, "error" => error_msg} = _event, state) do
    case Map.pop(state.pending_commands, correlation_id) do
      {nil, _} ->
        state

      {{from, timer_ref}, pending_commands} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:error, error_msg})
        %{state | pending_commands: pending_commands}
    end
  end

  defp handle_command_error(_event, state), do: state

  # ============================================================================
  # Private — outbound dispatch
  # ============================================================================

  defp dispatch_outbound(port_server, %{kind: :send_text} = payload, correlation_id) do
    Bridge.send_text(port_server, %{
      id: correlation_id,
      jid: payload.jid,
      text: payload.text,
      reply_to: payload[:reply_to_id]
    })

    :ok
  rescue
    e -> {:error, e}
  end

  defp dispatch_outbound(port_server, %{kind: :send_media} = payload, correlation_id) do
    media_type =
      cond do
        is_binary(payload[:mime_type]) and String.starts_with?(payload[:mime_type], "image/") ->
          "image"

        is_binary(payload[:mime_type]) and String.starts_with?(payload[:mime_type], "audio/") ->
          "audio"

        true ->
          "document"
      end

    Bridge.send_media(port_server, %{
      id: correlation_id,
      jid: payload.jid,
      file_path: payload.path,
      media_type: media_type,
      caption: payload[:caption]
    })

    :ok
  rescue
    e -> {:error, e}
  end

  defp dispatch_outbound(port_server, %{kind: :send_reaction} = payload, correlation_id) do
    Bridge.send_reaction(port_server, %{
      id: correlation_id,
      jid: payload.jid,
      message_id: payload.message_id,
      emoji: payload.emoji
    })

    :ok
  rescue
    e -> {:error, e}
  end

  defp dispatch_outbound(_port_server, payload, _correlation_id) do
    {:error, {:unsupported_payload_kind, payload[:kind]}}
  end

  # ============================================================================
  # Private — reconnection
  # ============================================================================

  defp schedule_reconnect(state) do
    if state.reconnect_attempts >= @reconnect_max_attempts do
      Logger.error(
        "whatsapp max reconnect attempts (#{@reconnect_max_attempts}) reached; giving up"
      )

      state
    else
      delay = backoff_delay(state.reconnect_attempts)

      Logger.info(
        "whatsapp reconnect scheduled in #{delay}ms (attempt #{state.reconnect_attempts + 1})"
      )

      timer = Process.send_after(self(), :reconnect, delay)

      %{state | reconnect_timer: timer, reconnect_attempts: state.reconnect_attempts + 1}
    end
  end

  defp backoff_delay(attempt) do
    base = @reconnect_initial_ms * :math.pow(@reconnect_factor, attempt)
    capped = min(base, @reconnect_max_ms)
    jitter = capped * @reconnect_jitter * (:rand.uniform() * 2 - 1)
    round(capped + jitter)
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    nil
  end

  # ============================================================================
  # Private — helpers
  # ============================================================================

  defp access_config(state) do
    cfg = state.config || %{}
    own_jid = state.own_jid

    if is_binary(own_jid) do
      Map.put(cfg, :own_jid, own_jid)
    else
      cfg
    end
  end

  defp generate_correlation_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp phone_from_jid(nil), do: nil

  defp phone_from_jid(jid) when is_binary(jid) do
    case String.split(jid, "@", parts: 2) do
      [local, _] when local != "" -> local
      _ -> nil
    end
  end

  defp phone_from_jid(_), do: nil

  defp cfg_get(cfg, key, default) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, to_string(key)) || default
  end

  defp cfg_get(_cfg, _key, default), do: default

  defp normalize_map(nil), do: %{}
  defp normalize_map(m) when is_map(m), do: m
  defp normalize_map(_), do: %{}

  defp merge_opts(cfg, opts) when is_list(opts) do
    overrides =
      opts
      |> Keyword.get(:config, [])
      |> List.wrap()
      |> Enum.into(%{})

    extra =
      opts
      |> Keyword.drop([:config])
      |> Enum.into(%{})

    cfg
    |> Map.merge(normalize_map(overrides))
    |> Map.merge(extra)
  end

  defp merge_opts(cfg, _opts), do: cfg
end
