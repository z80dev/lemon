defmodule LemonGateway.Voice.TwilioWebSocket do
  @moduledoc """
  WebSocket handler for Twilio Media Streams.

  Handles the WebSocket connection from Twilio for a voice call,
  receiving audio (mulaw 8kHz) and sending synthesized speech back.
  """

  @behaviour WebSock

  require Logger

  alias LemonGateway.Voice.{CallSession, Config, DeepgramClient, RecordingManager}

  # WebSock Callbacks

  @impl WebSock
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    call_sid = Keyword.fetch!(opts, :call_sid)
    from_number = Keyword.get(opts, :from_number, "unknown")
    to_number = Keyword.get(opts, :to_number, "unknown")

    Logger.info("Twilio WebSocket initializing for call #{call_sid}")

    session_pid = ensure_call_session(call_sid, from_number, to_number)
    deepgram_pid = ensure_deepgram_client(call_sid, session_pid)

    state = %{
      call_sid: call_sid,
      session_pid: session_pid,
      deepgram_pid: deepgram_pid,
      stream_sid: nil,
      audio_buffer: <<>>
    }

    # Register with call session
    CallSession.register_twilio_ws(session_pid, self())

    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, data} ->
        handle_twilio_message(data, state)

      {:error, reason} ->
        Logger.warning("Failed to decode Twilio message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_in({data, [opcode: :binary]}, state) do
    # Twilio shouldn't send binary frames, but handle just in case
    Logger.debug("Received binary frame from Twilio: #{byte_size(data)} bytes")
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:send_audio, audio_data}, state) do
    # Send audio back to Twilio
    # Twilio expects base64-encoded mulaw audio in a Media message
    encoded = Base.encode64(audio_data)

    message = %{
      "event" => "media",
      "streamSid" => state.stream_sid,
      "media" => %{
        "payload" => encoded
      }
    }

    frame = {:text, Jason.encode!(message)}
    {:push, frame, state}
  end

  def handle_info({:send_mark, name}, state) do
    # Send a mark to track when audio finishes playing
    message = %{
      "event" => "mark",
      "streamSid" => state.stream_sid,
      "mark" => %{"name" => name}
    }

    frame = {:text, Jason.encode!(message)}
    {:push, frame, state}
  end

  def handle_info(:clear_audio, state) do
    # Clear the audio buffer
    message = %{
      "event" => "clear",
      "streamSid" => state.stream_sid
    }

    frame = {:text, Jason.encode!(message)}
    {:push, frame, state}
  end

  def handle_info(:speech_complete, state) do
    # Notify call session that speech finished
    if is_pid(state.session_pid) do
      send(state.session_pid, :speech_complete)
    end

    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in TwilioWebSocket: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("Twilio WebSocket terminated for call #{state.call_sid}: #{inspect(reason)}")

    # End the call session
    CallSession.end_call(state.session_pid)

    :ok
  end

  # Private Functions

  defp handle_twilio_message(%{"event" => "connected"} = data, state) do
    Logger.debug("Twilio stream connected: #{inspect(data)}")
    {:ok, state}
  end

  defp handle_twilio_message(%{"event" => "start"} = data, state) do
    stream_sid = dig_in(data, ["start", "streamSid"])
    call_sid = dig_in(data, ["start", "callSid"])

    if is_binary(call_sid) and call_sid != state.call_sid and
         not provisional_call_sid?(state.call_sid) do
      Logger.warning(
        "Twilio call SID mismatch for stream #{stream_sid}: websocket_sid=#{state.call_sid}, twilio_sid=#{call_sid}"
      )
    end

    Logger.info("Twilio stream started: stream_sid=#{stream_sid}, call_sid=#{call_sid}")

    # Start recording via Twilio REST API (dual-channel)
    actual_call_sid = call_sid || state.call_sid
    start_call_recording(actual_call_sid)

    {:ok, %{state | stream_sid: stream_sid, call_sid: actual_call_sid}}
  end

  defp handle_twilio_message(%{"event" => "media"} = data, state) do
    payload = dig_in(data, ["media", "payload"])
    track = dig_in(data, ["media", "track"])

    # Process inbound caller audio. Some providers omit `track` on inbound frames.
    if payload && (track == "inbound" || is_nil(track)) do
      # Decode base64 mulaw audio
      audio_data = Base.decode64!(payload)

      # Route through CallSession so activity timestamps are updated.
      CallSession.handle_audio(state.session_pid, audio_data)

      # Also buffer for potential processing
      {:ok, %{state | audio_buffer: state.audio_buffer <> audio_data}}
    else
      {:ok, state}
    end
  end

  defp handle_twilio_message(%{"event" => "mark"} = data, state) do
    mark_name = dig_in(data, ["mark", "name"])
    Logger.debug("Mark received: #{mark_name}")

    # Notify call session that speech finished
    send(self(), :speech_complete)

    {:ok, state}
  end

  defp handle_twilio_message(%{"event" => "stop"} = data, state) do
    Logger.info("Twilio stream stopped: #{inspect(data)}")

    # End the call session
    CallSession.end_call(state.session_pid)

    {:stop, :normal, state}
  end

  defp handle_twilio_message(data, state) do
    Logger.debug("Unhandled Twilio message: #{inspect(data)}")
    {:ok, state}
  end

  defp dig_in(data, keys) do
    Enum.reduce(keys, data, fn key, acc ->
      if is_map(acc), do: Map.get(acc, key), else: nil
    end)
  end

  defp provisional_call_sid?(call_sid) when is_binary(call_sid) do
    String.starts_with?(call_sid, "temp_")
  end

  defp provisional_call_sid?(_), do: false

  defp ensure_call_session(call_sid, from_number, to_number) do
    case DynamicSupervisor.start_child(
           LemonGateway.Voice.CallSessionSupervisor,
           {CallSession, call_sid: call_sid, from_number: from_number, to_number: to_number}
         ) do
      {:ok, session_pid} ->
        session_pid

      {:error, {:already_started, session_pid}} ->
        Logger.warning("Reusing existing call session for call #{call_sid}")
        session_pid

      {:error, reason} ->
        raise "Failed to start call session for #{call_sid}: #{inspect(reason)}"
    end
  end

  defp ensure_deepgram_client(call_sid, session_pid) do
    case DynamicSupervisor.start_child(
           LemonGateway.Voice.DeepgramSupervisor,
           {DeepgramClient, call_sid: call_sid, session_pid: session_pid}
         ) do
      {:ok, deepgram_pid} ->
        deepgram_pid

      {:error, {:already_started, deepgram_pid}} ->
        Logger.warning("Reusing existing Deepgram client for call #{call_sid}")
        deepgram_pid

      {:error, reason} ->
        raise "Failed to start Deepgram client for #{call_sid}: #{inspect(reason)}"
    end
  end

  defp start_call_recording(call_sid) do
    # Build the recording status callback URL from the public URL config
    callback_opts =
      case Config.public_url() do
        nil ->
          Logger.warning("No VOICE_PUBLIC_URL configured — recording callback won't fire")
          []

        public_url ->
          base = String.trim_trailing(public_url, "/")
          [recording_callback_url: "#{base}/webhooks/twilio/voice/recording"]
      end

    # Start recording in a background task so we don't block the WebSocket
    Task.start(fn ->
      case RecordingManager.start_recording(call_sid, callback_opts) do
        {:ok, recording_sid} ->
          Logger.info("Recording #{recording_sid} started for call #{call_sid}")

        {:error, reason} ->
          Logger.error("Failed to start recording for #{call_sid}: #{inspect(reason)}")
      end
    end)
  end
end
