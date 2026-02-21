defmodule LemonGateway.Voice.DeepgramClient do
  @moduledoc """
  WebSocket client for Deepgram streaming speech-to-text.

  Uses WebSockex to connect to Deepgram's real-time transcription API
  and forward transcripts to the call session.
  """

  use WebSockex

  require Logger

  alias LemonGateway.Voice.{CallSession, Config}

  @deepgram_ws_url "wss://api.deepgram.com/v1/listen"

  # Client API

  @doc """
  Starts a Deepgram WebSocket connection for a call session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    call_sid = Keyword.fetch!(opts, :call_sid)
    session_pid = Keyword.fetch!(opts, :session_pid)

    # Build Deepgram URL with parameters
    url = build_deepgram_url()

    headers = [
      {"Authorization", "Token #{Config.deepgram_api_key()}"}
    ]

    WebSockex.start_link(
      url,
      __MODULE__,
      %{call_sid: call_sid, session_pid: session_pid},
      extra_headers: headers,
      name: via_tuple(call_sid)
    )
  end

  @doc """
  Returns the via tuple for registry lookup.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_tuple(call_sid) do
    {:via, Registry, {LemonGateway.Voice.DeepgramRegistry, call_sid}}
  end

  @doc """
  Sends audio data to Deepgram for transcription.
  """
  @spec send_audio(pid(), binary()) :: :ok
  def send_audio(pid, audio_data) do
    WebSockex.cast(pid, {:send_audio, audio_data})
  end

  # WebSockex Callbacks

  def init(state) do
    Logger.debug("Deepgram client initialized for call #{state.call_sid}")
    {:ok, state}
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.debug("Connected to Deepgram for call #{state.call_sid}")

    # Register with call session
    CallSession.register_deepgram_ws(state.session_pid, self())

    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, data} ->
        handle_deepgram_message(data, state)

      {:error, reason} ->
        Logger.warning("Failed to decode Deepgram message: #{inspect(reason)}")
    end

    {:ok, state}
  end

  def handle_frame({:binary, _data}, state) do
    # Deepgram shouldn't send binary frames
    {:ok, state}
  end

  @impl WebSockex
  def handle_cast({:send_audio, audio_data}, state) do
    # Deepgram expects raw audio bytes
    {:reply, {:binary, audio_data}, state}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("Deepgram disconnected for call #{state.call_sid}: #{inspect(reason)}")
    {:ok, state}
  end

  @impl WebSockex
  def terminate(reason, state) do
    Logger.debug("Deepgram client terminated for call #{state.call_sid}: #{inspect(reason)}")
  end

  # Private Functions

  defp build_deepgram_url do
    params = %{
      encoding: "mulaw",
      sample_rate: 8000,
      channels: 1,
      model: "nova-2",
      interim_results: "true",
      punctuate: "true",
      smart_format: "true",
      filler_words: "false",
      profanity_filter: "false"
    }

    query =
      params
      |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(v)}" end)
      |> Enum.join("&")

    "#{@deepgram_ws_url}?#{query}"
  end

  defp handle_deepgram_message(%{"type" => "Results"} = data, state) do
    # Forward transcript to call session
    CallSession.handle_transcript(state.session_pid, data)
  end

  defp handle_deepgram_message(%{"type" => "Metadata"} = data, _state) do
    Logger.debug("Deepgram metadata: #{inspect(data)}")
  end

  defp handle_deepgram_message(%{"type" => "UtteranceEnd"}, state) do
    Logger.debug("Utterance ended for call #{state.call_sid}")
  end

  defp handle_deepgram_message(%{"type" => "SpeechStarted"}, _state) do
    :ok
  end

  defp handle_deepgram_message(%{"type" => "Final"} = data, state) do
    # Alternative format for final results
    CallSession.handle_transcript(state.session_pid, %{
      "is_final" => true,
      "channel" => %{"alternatives" => [Map.take(data, ["transcript", "confidence"])]}
    })
  end

  defp handle_deepgram_message(data, _state) do
    Logger.debug("Unhandled Deepgram message: #{inspect(data)}")
  end
end
