defmodule LemonMedia.Providers.DeepgramStream do
  @moduledoc """
  WebSocket client for Deepgram streaming speech-to-text.

  The caller owns supervision and receives connection and transcript callbacks.
  """

  # A Deepgram socket belongs to exactly one call: never restart it, so a
  # disconnect cannot leave a replacement socket attached to an ended call.
  use WebSockex, restart: :temporary

  require Logger

  @deepgram_ws_url "wss://api.deepgram.com/v1/listen"

  # Client API

  @doc """
  Starts a Deepgram WebSocket for 8 kHz mono μ-law audio.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    state = %{
      on_connect: Keyword.fetch!(opts, :on_connect),
      on_transcript: Keyword.fetch!(opts, :on_transcript)
    }

    with {:ok, url, ws_opts} <- connect_options(build_deepgram_url(), opts) do
      WebSockex.start_link(
        url,
        __MODULE__,
        state,
        ws_opts
      )
    end
  end

  @doc false
  @spec connect_options(String.t(), keyword()) ::
          {:ok, String.t(), keyword()} | {:error, term()}
  def connect_options(url, opts) do
    LemonCore.Net.web_socket_options(url,
      extra_headers: [{"Authorization", "Token #{Keyword.fetch!(opts, :api_key)}"}],
      name: Keyword.fetch!(opts, :name)
    )
  end

  @doc """
  Sends audio data to Deepgram for transcription.
  """
  @spec send_audio(pid(), binary()) :: :ok
  def send_audio(pid, audio_data) do
    WebSockex.cast(pid, {:send_audio, audio_data})
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    state.on_connect.(self())

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
  def handle_disconnect(_status, state) do
    Logger.debug("Deepgram stream disconnected")
    {:ok, state}
  end

  # Private Functions

  defp build_deepgram_url do
    params = %{
      encoding: "mulaw",
      sample_rate: "8000",
      channels: "1",
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
    state.on_transcript.(data)
  end

  defp handle_deepgram_message(%{"type" => "Metadata"} = data, _state) do
    Logger.debug("Deepgram metadata: #{inspect(data)}")
  end

  defp handle_deepgram_message(%{"type" => "UtteranceEnd"}, _state) do
    Logger.debug("Deepgram utterance ended")
  end

  defp handle_deepgram_message(%{"type" => "SpeechStarted"}, _state) do
    :ok
  end

  defp handle_deepgram_message(%{"type" => "Final"} = data, state) do
    state.on_transcript.(%{
      "is_final" => true,
      "channel" => %{"alternatives" => [Map.take(data, ["transcript", "confidence"])]}
    })
  end

  defp handle_deepgram_message(data, _state) do
    Logger.debug("Unhandled Deepgram message: #{inspect(data)}")
  end
end
