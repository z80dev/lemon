defmodule LemonGateway.Voice.CallSession do
  @moduledoc """
  GenServer that manages a single voice call session.

  Handles:
  - WebSocket connections (Twilio + Deepgram)
  - Audio streaming and buffering
  - Speech-to-text processing
  - LLM response generation
  - Text-to-speech synthesis
  - Call state management
  """

  use GenServer

  require Logger

  alias LemonGateway.Voice.Config

  # Call states
  defstruct [
    :call_sid,
    :from_number,
    :to_number,
    :twilio_ws_pid,
    :deepgram_ws_pid,
    :started_at,
    :last_activity_at,
    :current_utterance,
    :is_speaking,
    :is_processing,
    :response_queue,
    :session_key,
    :conversation_history,
    :interruption_detected
  ]

  @type t :: %__MODULE__{
    call_sid: String.t(),
    from_number: String.t(),
    to_number: String.t(),
    twilio_ws_pid: pid() | nil,
    deepgram_ws_pid: pid() | nil,
    started_at: DateTime.t(),
    last_activity_at: DateTime.t(),
    current_utterance: String.t(),
    is_speaking: boolean(),
    is_processing: boolean(),
    response_queue: list(),
    session_key: String.t(),
    conversation_history: list(),
    interruption_detected: boolean()
  }

  # Client API

  @doc """
  Starts a new call session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    call_sid = Keyword.fetch!(opts, :call_sid)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(call_sid))
  end

  @doc """
  Returns the via tuple for registry lookup.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_tuple(call_sid) do
    {:via, Registry, {LemonGateway.Voice.CallRegistry, call_sid}}
  end

  @doc """
  Looks up a call session by call SID.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(call_sid) do
    case Registry.lookup(LemonGateway.Voice.CallRegistry, call_sid) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Registers the Twilio WebSocket connection.
  """
  @spec register_twilio_ws(pid(), pid()) :: :ok
  def register_twilio_ws(session_pid, ws_pid) do
    GenServer.cast(session_pid, {:register_twilio_ws, ws_pid})
  end

  @doc """
  Registers the Deepgram WebSocket connection.
  """
  @spec register_deepgram_ws(pid(), pid()) :: :ok
  def register_deepgram_ws(session_pid, ws_pid) do
    GenServer.cast(session_pid, {:register_deepgram_ws, ws_pid})
  end

  @doc """
  Handles incoming audio from Twilio (mulaw 8kHz).
  """
  @spec handle_audio(pid(), binary()) :: :ok
  def handle_audio(session_pid, audio_data) do
    GenServer.cast(session_pid, {:audio_from_twilio, audio_data})
  end

  @doc """
  Handles transcript from Deepgram.
  """
  @spec handle_transcript(pid(), map()) :: :ok
  def handle_transcript(session_pid, transcript_data) do
    GenServer.cast(session_pid, {:transcript, transcript_data})
  end

  @doc """
  Sends a text response to be spoken.
  """
  @spec speak(pid(), String.t()) :: :ok
  def speak(session_pid, text) do
    GenServer.cast(session_pid, {:speak, text})
  end

  @doc """
  Ends the call session.
  """
  @spec end_call(pid()) :: :ok
  def end_call(session_pid) do
    GenServer.cast(session_pid, :end_call)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    call_sid = Keyword.fetch!(opts, :call_sid)
    from_number = Keyword.get(opts, :from_number, "unknown")
    to_number = Keyword.get(opts, :to_number, "unknown")

    # Generate session key from phone number
    session_key = "voice:#{from_number}"

    state = %__MODULE__{
      call_sid: call_sid,
      from_number: from_number,
      to_number: to_number,
      twilio_ws_pid: nil,
      deepgram_ws_pid: nil,
      started_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now(),
      current_utterance: "",
      is_speaking: false,
      is_processing: false,
      response_queue: [],
      session_key: session_key,
      conversation_history: [],
      interruption_detected: false
    }

    # Start call timeout timer
    schedule_call_timeout()

    # Send welcome message
    send(self(), :send_welcome)

    Logger.info("Voice call session started: #{call_sid} from #{from_number}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:register_twilio_ws, ws_pid}, state) do
    Logger.debug("Twilio WebSocket registered for call #{state.call_sid}")
    {:noreply, %{state | twilio_ws_pid: ws_pid}}
  end

  def handle_cast({:register_deepgram_ws, ws_pid}, state) do
    Logger.debug("Deepgram WebSocket registered for call #{state.call_sid}")
    {:noreply, %{state | deepgram_ws_pid: ws_pid}}
  end

  def handle_cast({:audio_from_twilio, audio_data}, state) do
    # Forward audio to Deepgram for transcription
    if state.deepgram_ws_pid do
      send(state.deepgram_ws_pid, {:audio, audio_data})
    end

    {:noreply, %{state | last_activity_at: DateTime.utc_now()}}
  end

  def handle_cast({:transcript, %{"is_final" => true, "channel" => %{"alternatives" => alternatives}}}, state) do
    transcript = get_best_transcript(alternatives)

    if transcript != "" do
      Logger.info("Final transcript for #{state.call_sid}: #{transcript}")

      # Add to conversation history
      history = state.conversation_history ++ [%{role: "user", content: transcript}]

      # Generate response
      new_state = %{state | conversation_history: history, current_utterance: ""}
      send(self(), :generate_response)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:transcript, %{"is_final" => false, "channel" => %{"alternatives" => alternatives}}}, state) do
    # Interim transcript - update current utterance for interruption detection
    transcript = get_best_transcript(alternatives)
    {:noreply, %{state | current_utterance: transcript}}
  end

  def handle_cast({:transcript, _}, state) do
    {:noreply, state}
  end

  def handle_cast({:speak, text}, state) do
    if state.is_speaking do
      # Queue the response
      {:noreply, %{state | response_queue: state.response_queue ++ [text]}}
    else
      # Start speaking immediately
      send(self(), {:synthesize_speech, text})
      {:noreply, %{state | is_speaking: true}}
    end
  end

  def handle_cast(:end_call, state) do
    Logger.info("Ending call session: #{state.call_sid}")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:send_welcome, state) do
    welcome_text = "Hey there! This is zeebot. What can I help you with?"
    send(self(), {:synthesize_speech, welcome_text})
    {:noreply, %{state | is_speaking: true}}
  end

  def handle_info(:generate_response, state) do
    # Call LLM to generate response
    Task.start(fn ->
      response = generate_llm_response(state.conversation_history)
      speak(self(), response)
    end)

    {:noreply, %{state | is_processing: true}}
  end

  def handle_info({:synthesize_speech, text}, state) do
    # Synthesize speech using ElevenLabs
    Task.start(fn ->
      case synthesize_speech(text) do
        {:ok, audio_data} ->
          send(self(), {:audio_ready, audio_data, text})
        {:error, reason} ->
          Logger.error("TTS failed: #{inspect(reason)}")
          send(self(), :speech_complete)
      end
    end)

    {:noreply, state}
  end

  def handle_info({:audio_ready, audio_data, text}, state) do
    # Convert PCM to mulaw and send to Twilio
    mulaw_audio = convert_pcm_to_mulaw(audio_data)

    if state.twilio_ws_pid do
      send(state.twilio_ws_pid, {:send_audio, mulaw_audio})
    end

    # Add assistant response to history
    history = state.conversation_history ++ [%{role: "assistant", content: text}]

    {:noreply, %{state | conversation_history: history, is_processing: false}}
  end

  def handle_info(:speech_complete, state) do
    # Check if there are more responses in queue
    case state.response_queue do
      [next | rest] ->
        send(self(), {:synthesize_speech, next})
        {:noreply, %{state | response_queue: rest}}

      [] ->
        {:noreply, %{state | is_speaking: false}}
    end
  end

  def handle_info(:call_timeout, state) do
    # Check if call has been inactive
    inactive_ms = DateTime.diff(DateTime.utc_now(), state.last_activity_at, :millisecond)

    if inactive_ms > Config.silence_timeout_ms() do
      Logger.info("Call #{state.call_sid} timed out due to inactivity")
      speak(self(), "Thanks for calling! Goodbye.")
      Process.send_after(self(), :end_call, 3000)
    end

    schedule_call_timeout()
    {:noreply, state}
  end

  def handle_info(:end_call, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Call session terminated: #{state.call_sid}")
    :ok
  end

  # Private Functions

  defp get_best_transcript(alternatives) when is_list(alternatives) do
    case alternatives do
      [%{"transcript" => transcript} | _] -> transcript
      _ -> ""
    end
  end

  defp get_best_transcript(_), do: ""

  defp generate_llm_response(history) do
    messages = [
      %{role: "system", content: Config.system_prompt()}
      | Enum.take(history, -10) # Keep last 10 messages for context
    ]

    # Use the AI module to generate response
    case LemonGateway.AI.chat_completion(Config.llm_model(), messages, %{max_tokens: 150}) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        content
      {:ok, %{"content" => content}} ->
        content
      _ ->
        "I'm sorry, I didn't catch that. Could you say it again?"
    end
  end

  defp synthesize_speech(text) do
    api_key = Config.elevenlabs_api_key()
    voice_id = Config.elevenlabs_voice_id()

    url = "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}/stream"

    headers = [
      {"xi-api-key", api_key},
      {"content-type", "application/json"}
    ]

    body = Jason.encode!(%{
      text: text,
      model_id: "eleven_turbo_v2_5",
      voice_settings: %{
        stability: 0.5,
        similarity_boost: 0.75
      }
    })

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [timeout: 10_000],
           []
         ) do
      {:ok, {{_, 200, _}, _headers, response_body}} ->
        {:ok, response_body}

      {:ok, {{_, status, _}, _headers, response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_pcm_to_mulaw(pcm_data) do
    # ElevenLabs returns MP3 or PCM, we need to convert to mulaw 8kHz for Twilio
    # For now, assume we get PCM and do basic conversion
    # In production, use FFmpeg or similar

    # This is a placeholder - real implementation needs proper audio conversion
    # Twilio expects 8000Hz, mono, mulaw encoded audio
    pcm_data
  end

  defp schedule_call_timeout do
    Process.send_after(self(), :call_timeout, 5000)
  end
end
