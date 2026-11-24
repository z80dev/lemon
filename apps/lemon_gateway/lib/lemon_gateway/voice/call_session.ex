defmodule LemonGateway.Voice.CallSession do
  @moduledoc """
  State machine owning one voice call and its supervised LLM/TTS tasks.

  | State | Event | Next state |
  | --- | --- | --- |
  | `:idle` | queued transcript / speech | `:generating` / `:synthesizing` |
  | `:generating` | LLM result | `:synthesizing` |
  | `:synthesizing` | audio, failure or timeout | next queued job, or `:idle` |
  | `:generating` | failure or timeout | next queued job, or `:idle` |
  | any active state | silence deadline | `:closing` (bounded goodbye) |
  | `:closing` | shutdown deadline | stopped |
  | any state | end call | stopped |

  Incoming work is FIFO; a generated answer is synthesized before the next job.
  Task results are matched by monitor reference, so expired work cannot publish
  audio or advance another job. Twilio playback marks are best-effort and never
  advance synthesis. Generic inactivity timeouts reset only on incoming audio;
  unrelated traffic cannot postpone either a task deadline or call shutdown.

  `start_link/1` accepts `:llm_timeout_ms` (30 seconds) and `:tts_timeout_ms`
  (10 seconds), matching the existing HTTP request policies, and
  `:silence_timeout_ms` (the configured voice silence policy). Per-call
  `:llm_fun`, `:tts_fun` and `:task_supervisor` dependencies can be supplied by
  embedders; defaults use the gateway providers and `LemonGateway.TaskSupervisor`.
  """

  @behaviour :gen_statem

  require Logger

  alias LemonGateway.Voice.{AudioConversion, Config, DeepgramClient}
  alias LemonMedia.Providers.Speech

  defstruct [
    :call_sid,
    :from_number,
    :to_number,
    :twilio_ws_pid,
    :deepgram_ws_pid,
    :started_at,
    :last_activity_at,
    :current_utterance,
    :session_key,
    :conversation_history,
    :task,
    :speech_text,
    :llm_fun,
    :tts_fun,
    :task_supervisor,
    :llm_timeout_ms,
    :tts_timeout_ms,
    :silence_timeout_ms,
    jobs: {[], []}
  ]

  @type t :: %__MODULE__{}

  @doc "Starts a new call session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    call_sid = Keyword.fetch!(opts, :call_sid)
    :gen_statem.start_link(via_tuple(call_sid), __MODULE__, opts, [])
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Returns the via tuple for registry lookup."
  @spec via_tuple(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_tuple(call_sid) do
    {:via, Registry, {LemonGateway.Voice.CallRegistry, call_sid}}
  end

  @doc "Looks up a call session by call SID."
  @spec lookup(String.t()) :: pid() | nil
  def lookup(call_sid) do
    case Registry.lookup(LemonGateway.Voice.CallRegistry, call_sid) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Registers the Twilio WebSocket connection."
  @spec register_twilio_ws(pid(), pid()) :: :ok
  def register_twilio_ws(session_pid, ws_pid) do
    :gen_statem.cast(session_pid, {:register_twilio_ws, ws_pid})
  end

  @doc "Registers the Deepgram WebSocket connection."
  @spec register_deepgram_ws(pid(), pid()) :: :ok
  def register_deepgram_ws(session_pid, ws_pid) do
    :gen_statem.cast(session_pid, {:register_deepgram_ws, ws_pid})
  end

  @doc "Handles incoming audio from Twilio (mulaw 8kHz)."
  @spec handle_audio(pid(), binary()) :: :ok
  def handle_audio(session_pid, audio_data) do
    :gen_statem.cast(session_pid, {:audio_from_twilio, audio_data})
  end

  @doc "Handles transcript from Deepgram."
  @spec handle_transcript(pid(), map()) :: :ok
  def handle_transcript(session_pid, transcript_data) do
    :gen_statem.cast(session_pid, {:transcript, transcript_data})
  end

  @doc "Sends a text response to be spoken."
  @spec speak(pid(), String.t()) :: :ok
  def speak(session_pid, text) do
    :gen_statem.cast(session_pid, {:speak, text})
  end

  @doc "Ends the call session."
  @spec end_call(pid()) :: :ok
  def end_call(session_pid) do
    :gen_statem.cast(session_pid, :end_call)
  end

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    # Supervised tasks are also linked to this owner, so even an untrappable
    # owner death cannot leave provider work running. Task failures arrive as DOWN.
    Process.flag(:trap_exit, true)

    call_sid = Keyword.fetch!(opts, :call_sid)
    from_number = Keyword.get(opts, :from_number, "unknown")

    data = %__MODULE__{
      call_sid: call_sid,
      from_number: from_number,
      to_number: Keyword.get(opts, :to_number, "unknown"),
      started_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now(),
      current_utterance: "",
      session_key: "voice:#{from_number}",
      conversation_history: [],
      llm_fun: Keyword.get(opts, :llm_fun, &generate_llm_response/1),
      tts_fun: Keyword.get(opts, :tts_fun, &synthesize_speech/1),
      task_supervisor: Keyword.get(opts, :task_supervisor, LemonGateway.TaskSupervisor),
      llm_timeout_ms: Keyword.get(opts, :llm_timeout_ms, 30_000),
      tts_timeout_ms: Keyword.get(opts, :tts_timeout_ms, 10_000),
      silence_timeout_ms: Keyword.get(opts, :silence_timeout_ms, Config.silence_timeout_ms())
    }

    Logger.info("Voice call session started: #{call_sid} from #{from_number}")

    {:ok, :idle, data,
     [
       {{:timeout, :silence}, data.silence_timeout_ms, :inactive},
       {:next_event, :internal, {:speak, "Hey there! This is zeebot. What can I help you with?"}}
     ]}
  end

  @impl true
  def handle_event(:cast, :end_call, _state, data), do: {:stop, :normal, data}

  def handle_event(:cast, {:register_twilio_ws, pid}, _state, data) do
    {:keep_state, %{data | twilio_ws_pid: pid}}
  end

  def handle_event(:cast, {:register_deepgram_ws, pid}, _state, data) do
    # Linked so even an untrappable session death takes the Deepgram socket down;
    # the session traps exits, so a Deepgram disconnect does not end the call.
    Process.link(pid)
    {:keep_state, %{data | deepgram_ws_pid: pid}}
  end

  def handle_event(:cast, _event, :closing, _data), do: :keep_state_and_data

  def handle_event(:cast, {:audio_from_twilio, audio}, _state, data) do
    if data.deepgram_ws_pid, do: DeepgramClient.send_audio(data.deepgram_ws_pid, audio)

    {:keep_state, %{data | last_activity_at: DateTime.utc_now()},
     [{{:timeout, :silence}, data.silence_timeout_ms, :inactive}]}
  end

  def handle_event(
        :cast,
        {:transcript, %{"is_final" => true, "channel" => %{"alternatives" => alternatives}}},
        state,
        data
      ) do
    case get_best_transcript(alternatives) do
      "" ->
        :keep_state_and_data

      transcript ->
        history = [%{role: "user", content: transcript} | data.conversation_history]
        data = %{data | conversation_history: history, current_utterance: ""}
        enqueue({:generate, history}, state, data)
    end
  end

  def handle_event(
        :cast,
        {:transcript, %{"is_final" => false, "channel" => %{"alternatives" => alternatives}}},
        _state,
        data
      ) do
    {:keep_state, %{data | current_utterance: get_best_transcript(alternatives)}}
  end

  def handle_event(:cast, {:transcript, _}, _state, _data), do: :keep_state_and_data

  def handle_event(type, {:speak, text}, state, data) when type in [:cast, :internal] do
    enqueue({:speak, text}, state, data)
  end

  def handle_event(:info, {ref, result}, state, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil}
    finish_job(state, result, data)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        state,
        %{task: %Task{ref: ref}} = data
      ) do
    Logger.warning("Voice task failed for #{data.call_sid}: #{inspect(reason)}")
    advance(state, %{data | task: nil})
  end

  def handle_event({:timeout, :job}, :expired, state, data) do
    Logger.warning("Voice #{state} task timed out for #{data.call_sid}")
    stop_task(data.task)
    advance(state, %{data | task: nil})
  end

  def handle_event({:timeout, :silence}, :inactive, _state, data) do
    stop_task(data.task)
    data = %{data | task: nil, jobs: :queue.new()}
    {:next_state, :closing, data, [{:next_event, :internal, :goodbye}]}
  end

  def handle_event(:internal, :goodbye, :closing, data) do
    text = "Thanks for calling! Goodbye."
    fun = data.tts_fun
    task = start_task(data, fn -> fun.(text) end)

    {:keep_state, %{data | task: task, speech_text: text},
     [
       {{:timeout, :job}, data.tts_timeout_ms, :expired},
       {:state_timeout, 3_000, :end_call}
     ]}
  end

  def handle_event(:state_timeout, :end_call, :closing, data), do: {:stop, :normal, data}

  # Playback marks are not synthesis completions; stale task messages are ignored.
  def handle_event(:info, _message, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, data) do
    stop_task(data.task)

    # The session owns the call: close its Deepgram socket and the Twilio stream
    # however it ends (hang-up, silence, max duration, crash).
    DeepgramClient.stop(data.deepgram_ws_pid)
    if is_binary(data.call_sid), do: DeepgramClient.stop_for_call(data.call_sid)
    if is_pid(data.twilio_ws_pid), do: send(data.twilio_ws_pid, :call_ended)

    Logger.info("Call session terminated: #{data.call_sid}")
    :ok
  end

  defp enqueue(job, :idle, data), do: start_job(job, data)

  defp enqueue(job, _state, data) do
    {:keep_state, %{data | jobs: :queue.in(job, data.jobs)}}
  end

  defp start_job({:generate, history}, data) do
    fun = data.llm_fun
    task = start_task(data, fn -> fun.(history) end)

    {:next_state, :generating, %{data | task: task},
     [{{:timeout, :job}, data.llm_timeout_ms, :expired}]}
  end

  defp start_job({:speak, text}, data) do
    fun = data.tts_fun
    task = start_task(data, fn -> fun.(text) end)

    {:next_state, :synthesizing, %{data | task: task, speech_text: text},
     [{{:timeout, :job}, data.tts_timeout_ms, :expired}]}
  end

  defp start_task(data, fun) do
    Task.Supervisor.async(data.task_supervisor, fun)
  end

  defp stop_task(nil), do: :ok
  defp stop_task(%Task{} = task), do: Task.shutdown(task, :brutal_kill)

  defp finish_job(:generating, text, data) when is_binary(text) do
    start_job({:speak, text}, data)
  end

  defp finish_job(state, {:ok, audio}, data) when state in [:synthesizing, :closing] do
    mulaw_audio = convert_pcm_to_mulaw(audio)

    if data.twilio_ws_pid do
      send(data.twilio_ws_pid, {:send_audio, mulaw_audio})
    else
      Logger.warning("No Twilio WebSocket registered for call #{data.call_sid}; audio dropped")
    end

    history = [%{role: "assistant", content: data.speech_text} | data.conversation_history]
    advance(state, %{data | conversation_history: history})
  end

  defp finish_job(state, _failure, data), do: advance(state, data)

  defp advance(:closing, data) do
    {:keep_state, data, [{{:timeout, :job}, :cancel}]}
  end

  defp advance(_state, data) do
    case :queue.out(data.jobs) do
      {:empty, _queue} ->
        {:next_state, :idle, data, [{{:timeout, :job}, :cancel}]}

      {{:value, job}, jobs} ->
        start_job(job, %{data | jobs: jobs})
    end
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
    # History is stored in reverse order (prepended), so reverse to get chronological order
    messages = [
      %{role: "system", content: Config.system_prompt()}
      # Keep last 10 messages for context
      | history |> Enum.reverse() |> Enum.take(10)
    ]

    # Use the AI module to generate response
    case LemonGateway.AI.chat_completion(Config.llm_model(), messages, %{max_tokens: 150}) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        content

      {:ok, %{"content" => content}} ->
        content

      {:error, :missing_api_key} ->
        Logger.error("Voice LLM call failed for model #{Config.llm_model()}: missing API key")

        "I'm not fully configured yet. My language model API key is missing."

      {:error, reason} ->
        Logger.error("Voice LLM call failed for model #{Config.llm_model()}: #{inspect(reason)}")
        "I'm sorry, I'm having trouble thinking right now. Please try again."

      other ->
        Logger.error(
          "Voice LLM call returned unexpected payload for model #{Config.llm_model()}: #{inspect(other)}"
        )

        "I'm sorry, I didn't catch that. Could you say it again?"
    end
  end

  defp synthesize_speech(text) do
    case Config.elevenlabs_api_key() do
      key when is_binary(key) and key != "" -> synthesize_speech(text, key)
      _ -> {:error, :missing_api_key}
    end
  end

  defp synthesize_speech(text, api_key) do
    request = %{
      text: text,
      api_key: api_key,
      voice: Config.elevenlabs_voice_id(),
      output_format: Config.elevenlabs_output_format(),
      model: "eleven_turbo_v2_5",
      voice_settings: %{stability: 0.5, similarity_boost: 0.75},
      receive_timeout: 10_000
    }

    case Speech.elevenlabs_tts(request) do
      {:ok, audio} ->
        {:ok, audio}

      {:error, reason} = error ->
        Logger.warning("ElevenLabs TTS error: #{inspect(reason)}")
        error
    end
  end

  defp convert_pcm_to_mulaw(audio_data) do
    # ElevenLabs may return MP3 or raw PCM depending on configuration.
    # Twilio expects 8-bit mu-law (G.711) at 8000 Hz, mono.
    audio_binary = :erlang.iolist_to_binary(audio_data)
    output_format = Config.elevenlabs_output_format()

    cond do
      output_format == "ulaw_8000" ->
        # Already Twilio-compatible G.711 mu-law at 8kHz.
        audio_binary

      AudioConversion.mp3_data?(audio_binary) ->
        # MP3 data detected — mu-law encoding requires raw PCM input.
        # Log a warning; MP3 decoding requires an external step (e.g. ffmpeg)
        # that is out of scope for the pure-Elixir path. Pass through as-is
        # so the caller can observe the issue via Twilio playback artifacts.
        Logger.warning(
          "Audio data appears to be MP3-encoded; mu-law conversion requires PCM input. " <>
            "Set elevenlabs_output_format to ulaw_8000 for Twilio compatibility, " <>
            "or add an MP3 decode step."
        )

        audio_binary

      true ->
        # Assume 16-bit signed little-endian PCM — encode to mu-law
        AudioConversion.pcm16_to_mulaw(audio_binary)
    end
  end
end
