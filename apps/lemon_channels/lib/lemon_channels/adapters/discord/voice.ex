defmodule LemonChannels.Adapters.Discord.Voice do
  @moduledoc """
  Voice channel support for Discord adapter.

  Provides functionality for:
  - Joining/leaving voice channels
  - Playing audio (TTS, files)
  - Voice state management

  Requires Nostrum.Voice which uses ffmpeg for audio encoding.
  """

  require Logger

  alias Nostrum.Voice

  @doc """
  Join a voice channel.

  ## Options
  - `:self_deaf` - Whether to join deafened (default: false)
  - `:self_mute` - Whether to join muted (default: false)
  """
  @spec join(guild_id :: integer(), channel_id :: integer(), opts :: keyword()) ::
          :ok | {:error, term()}
  def join(guild_id, channel_id, opts \\ []) do
    self_deaf = Keyword.get(opts, :self_deaf, false)
    self_mute = Keyword.get(opts, :self_mute, false)

    case Voice.join_channel(guild_id, channel_id, self_deaf, self_mute) do
      :ok ->
        Logger.info("Discord voice: Joined channel #{channel_id} in guild #{guild_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Discord voice: Failed to join channel: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Leave the current voice channel in a guild.
  """
  @spec leave(guild_id :: integer()) :: :ok | {:error, term()}
  def leave(guild_id) do
    case Voice.leave_channel(guild_id) do
      :ok ->
        Logger.info("Discord voice: Left voice channel in guild #{guild_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Discord voice: Failed to leave channel: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Play audio in the current voice channel.

  ## Input types
  - File path (string ending in audio extension)
  - URL (http/https)
  - Raw audio data (binary with content_type option)

  ## Options
  - `:volume` - Volume level 0.0-2.0 (default: 1.0)
  - `:content_type` - MIME type for raw audio data
  - `:wait` - Whether to wait for playback to finish (default: true)
  """
  @spec play(guild_id :: integer(), input :: binary(), opts :: keyword()) ::
          :ok | {:error, term()}
  def play(guild_id, input, opts \\ []) do
    volume = Keyword.get(opts, :volume, 1.0)
    wait = Keyword.get(opts, :wait, true)

    # Determine input type and play
    result =
      cond do
        String.starts_with?(input, "http") ->
          Voice.play(guild_id, input, :url, volume: volume)

        File.exists?(input) ->
          Voice.play(guild_id, input, :file, volume: volume)

        is_binary(input) ->
          # Assume raw audio - write to temp file
          play_raw_audio(guild_id, input, opts)

        true ->
          {:error, :invalid_input}
      end

    case result do
      :ok when wait ->
        # Wait for playback to complete
        wait_for_playback(guild_id)

      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Discord voice: Failed to play audio: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stop current audio playback.
  """
  @spec stop(guild_id :: integer()) :: :ok | {:error, term()}
  def stop(guild_id) do
    Voice.stop(guild_id)
  end

  @doc """
  Pause current audio playback.
  """
  @spec pause(guild_id :: integer()) :: :ok | {:error, term()}
  def pause(guild_id) do
    Voice.pause(guild_id)
  end

  @doc """
  Resume paused audio playback.
  """
  @spec resume(guild_id :: integer()) :: :ok | {:error, term()}
  def resume(guild_id) do
    Voice.resume(guild_id)
  end

  @doc """
  Check if bot is currently in a voice channel for a guild.
  """
  @spec in_channel?(guild_id :: integer()) :: boolean()
  def in_channel?(guild_id) do
    Voice.get_channel_id(guild_id) != nil
  end

  @doc """
  Get the current voice channel ID for a guild.
  """
  @spec get_channel(guild_id :: integer()) :: integer() | nil
  def get_channel(guild_id) do
    Voice.get_channel_id(guild_id)
  end

  @doc """
  Check if audio is currently playing.
  """
  @spec playing?(guild_id :: integer()) :: boolean()
  def playing?(guild_id) do
    Voice.playing?(guild_id)
  end

  @doc """
  Speak text using TTS.

  Requires a TTS service to generate audio first.
  This is a convenience wrapper that:
  1. Generates TTS audio via configured TTS provider
  2. Plays the audio in voice channel

  ## Options
  - `:voice` - Voice ID for TTS provider
  - `:provider` - TTS provider (:elevenlabs, :piper, :gpu_services)
  """
  @spec speak(guild_id :: integer(), text :: binary(), opts :: keyword()) ::
          :ok | {:error, term()}
  def speak(guild_id, text, opts \\ []) do
    # Generate TTS audio
    case generate_tts(text, opts) do
      {:ok, audio_path} ->
        # Play the generated audio
        result = play(guild_id, audio_path, opts)
        # Cleanup temp file
        File.rm(audio_path)
        result

      {:error, reason} = error ->
        Logger.warning("Discord voice: TTS generation failed: #{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp play_raw_audio(guild_id, data, opts) do
    # Write to temp file
    ext = content_type_to_ext(opts[:content_type] || "audio/mp3")
    temp_path = Path.join(System.tmp_dir!(), "discord_voice_#{:rand.uniform(1_000_000)}#{ext}")

    case File.write(temp_path, data) do
      :ok ->
        result = Voice.play(guild_id, temp_path, :file, volume: opts[:volume] || 1.0)
        # Schedule cleanup after playback
        spawn(fn ->
          Process.sleep(30_000)  # Wait 30s before cleanup
          File.rm(temp_path)
        end)
        result

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp content_type_to_ext("audio/mp3"), do: ".mp3"
  defp content_type_to_ext("audio/mpeg"), do: ".mp3"
  defp content_type_to_ext("audio/ogg"), do: ".ogg"
  defp content_type_to_ext("audio/opus"), do: ".opus"
  defp content_type_to_ext("audio/wav"), do: ".wav"
  defp content_type_to_ext(_), do: ".mp3"

  defp wait_for_playback(guild_id) do
    if Voice.playing?(guild_id) do
      Process.sleep(100)
      wait_for_playback(guild_id)
    else
      :ok
    end
  end

  defp generate_tts(text, opts) do
    provider = opts[:provider] || :elevenlabs

    case provider do
      :elevenlabs ->
        generate_elevenlabs_tts(text, opts)

      :piper ->
        generate_piper_tts(text, opts)

      :gpu_services ->
        generate_gpu_services_tts(text, opts)

      _ ->
        {:error, {:unknown_provider, provider}}
    end
  end

  defp generate_elevenlabs_tts(text, opts) do
    # Use ElevenLabs API
    api_key = opts[:api_key] || System.get_env("ELEVENLABS_API_KEY")
    voice_id = opts[:voice] || "21m00Tcm4TlvDq8ikWAM"  # Default voice

    unless api_key do
      {:error, :no_api_key}
    else
      url = "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}"

      headers = [
        {"xi-api-key", api_key},
        {"Content-Type", "application/json"}
      ]

      body = Jason.encode!(%{
        text: text,
        model_id: "eleven_multilingual_v2"
      })

      case :httpc.request(
             :post,
             {to_charlist(url), Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end), ~c"application/json", body},
             [],
             body_format: :binary
           ) do
        {:ok, {{_, 200, _}, _headers, audio_data}} ->
          temp_path = Path.join(System.tmp_dir!(), "tts_#{:rand.uniform(1_000_000)}.mp3")
          File.write!(temp_path, audio_data)
          {:ok, temp_path}

        {:ok, {{_, status, _}, _, _}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_piper_tts(text, opts) do
    # Use local Piper TTS
    voice = opts[:voice] || "en_US-amy-medium"
    piper_path = opts[:piper_path] || "/usr/local/bin/piper/piper"
    voices_dir = opts[:voices_dir] || "/home/nuc/.local/share/piper-voices"

    model_path = Path.join(voices_dir, "#{voice}.onnx")
    temp_path = Path.join(System.tmp_dir!(), "tts_#{:rand.uniform(1_000_000)}.wav")

    cmd = "echo #{:binary.bin_to_list(text) |> Enum.map(&(&1)) |> to_string() |> String.replace("'", "\\'")} | #{piper_path} --model #{model_path} --output_file #{temp_path}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, temp_path}

      {output, code} ->
        {:error, {:piper_failed, code, output}}
    end
  end

  defp generate_gpu_services_tts(text, opts) do
    # Use GPU services API on endeavour
    base_url = opts[:base_url] || "http://100.81.187.69:8765"
    ref_audio = opts[:ref_audio]
    ref_text = opts[:ref_text]

    _temp_path = Path.join(System.tmp_dir!(), "tts_#{:rand.uniform(1_000_000)}.wav")

    # Build multipart form
    # This is a simplified version - in production you'd use a proper HTTP client
    _url = "#{base_url}/tts/f5"

    _form_data =
      if ref_audio do
        [{"text", text}, {"ref_audio", {:file, ref_audio}}, {"ref_text", ref_text || ""}]
      else
        [{"text", text}]
      end

    # For now, return error since multipart is complex with :httpc
    # In production, use Req or another HTTP client
    {:error, :gpu_services_not_implemented}
  end
end
