defmodule LemonControlPlane.Methods.TtsConvert do
  @moduledoc """
  Handler for the tts.convert control plane method.

  Converts text to speech audio.

  ## Supported Providers

  - `system` - Platform-specific TTS (macOS `say`, Linux `espeak`)
  - `openai` - OpenAI TTS API (requires API key)
  - `elevenlabs` - ElevenLabs API (requires API key)

  ## Configuration

  Enable TTS via store:
  ```elixir
  LemonCore.Store.put(:tts_config, :global, %{
    enabled: true,
    provider: "system",
    openai_api_key: "sk-...",
    elevenlabs_api_key: "..."
  })
  ```
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  require Logger

  @impl true
  def name, do: "tts.convert"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    text = params["text"]
    provider = params["provider"]
    voice = params["voice"]

    if is_nil(text) or text == "" do
      {:error, Errors.invalid_request("text is required")}
    else
      config = LemonCore.Store.get(:tts_config, :global) || %{}

      # Safe access supporting both atom and string keys (for JSONL reload)
      enabled = get_field(config, :enabled)
      config_provider = get_field(config, :provider)

      if not (enabled || false) do
        {:error, Errors.forbidden("TTS is not enabled")}
      else
        # Use specified provider or default from config
        active_provider = provider || config_provider || "system"

        case convert_text(text, active_provider, voice, config) do
          {:ok, audio_data, format} ->
            {:ok, %{
              "success" => true,
              "provider" => active_provider,
              "format" => format,
              "data" => Base.encode64(audio_data)
            }}

          {:error, :not_implemented, message} ->
            {:error, Errors.not_implemented(message)}

          {:error, reason} when is_binary(reason) ->
            {:error, Errors.internal_error("TTS conversion failed: #{reason}")}

          {:error, reason} ->
            {:error, Errors.internal_error("TTS conversion failed", inspect(reason))}
        end
      end
    end
  end

  defp convert_text(text, "system", voice, _config) do
    # Detect platform and use appropriate TTS command
    case :os.type() do
      {:unix, :darwin} ->
        convert_with_macos_say(text, voice)

      {:unix, _} ->
        convert_with_espeak(text, voice)

      {:win32, _} ->
        {:error, :not_implemented, "Windows TTS not yet implemented. Use openai or elevenlabs."}

      _ ->
        {:error, :not_implemented, "System TTS not available on this platform."}
    end
  end

  defp convert_text(text, "openai", voice, config) do
    api_key = get_field(config, :openai_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :not_implemented, "OpenAI TTS requires api key. Set openai_api_key in tts_config."}
    else
      convert_with_openai(text, voice || "alloy", api_key)
    end
  end

  defp convert_text(text, "elevenlabs", voice, config) do
    api_key = get_field(config, :elevenlabs_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :not_implemented, "ElevenLabs TTS requires api key. Set elevenlabs_api_key in tts_config."}
    else
      convert_with_elevenlabs(text, voice, api_key)
    end
  end

  defp convert_text(_text, provider, _voice, _config) do
    {:error, "Unknown TTS provider: #{provider}"}
  end

  # macOS TTS using `say` command with AIFF output converted to WAV
  defp convert_with_macos_say(text, voice) do
    # Create temp file for output
    tmp_dir = System.tmp_dir!()
    aiff_path = Path.join(tmp_dir, "tts_#{System.unique_integer([:positive])}.aiff")
    wav_path = Path.join(tmp_dir, "tts_#{System.unique_integer([:positive])}.wav")

    try do
      # Build say command with optional voice
      say_args = if voice, do: ["-v", voice, "-o", aiff_path, text], else: ["-o", aiff_path, text]

      case System.cmd("say", say_args, stderr_to_stdout: true) do
        {_, 0} ->
          # Convert AIFF to WAV using afconvert
          case System.cmd("afconvert", ["-f", "WAVE", "-d", "LEI16", aiff_path, wav_path], stderr_to_stdout: true) do
            {_, 0} ->
              case File.read(wav_path) do
                {:ok, data} -> {:ok, data, "audio/wav"}
                {:error, reason} -> {:error, "Failed to read output: #{inspect(reason)}"}
              end

            {output, _} ->
              # If afconvert fails, return AIFF directly
              case File.read(aiff_path) do
                {:ok, data} -> {:ok, data, "audio/aiff"}
                {:error, _} -> {:error, "afconvert failed: #{output}"}
              end
          end

        {output, _} ->
          {:error, "say command failed: #{output}"}
      end
    after
      # Cleanup temp files
      File.rm(aiff_path)
      File.rm(wav_path)
    end
  end

  # Linux TTS using espeak
  defp convert_with_espeak(text, voice) do
    tmp_dir = System.tmp_dir!()
    wav_path = Path.join(tmp_dir, "tts_#{System.unique_integer([:positive])}.wav")

    try do
      # Build espeak command with optional voice
      espeak_args = if voice do
        ["-v", voice, "-w", wav_path, text]
      else
        ["-w", wav_path, text]
      end

      case System.cmd("espeak", espeak_args, stderr_to_stdout: true) do
        {_, 0} ->
          case File.read(wav_path) do
            {:ok, data} -> {:ok, data, "audio/wav"}
            {:error, reason} -> {:error, "Failed to read output: #{inspect(reason)}"}
          end

        {output, code} ->
          # espeak might not be installed
          if code == 127 or String.contains?(output, "not found") do
            {:error, :not_implemented, "espeak not installed. Install with: apt install espeak"}
          else
            {:error, "espeak failed: #{output}"}
          end
      end
    after
      File.rm(wav_path)
    end
  end

  # OpenAI TTS API
  defp convert_with_openai(text, voice, api_key) do
    url = "https://api.openai.com/v1/audio/speech"

    body = Jason.encode!(%{
      "model" => "tts-1",
      "input" => text,
      "voice" => voice,
      "response_format" => "mp3"
    })

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case http_post(url, headers, body) do
      {:ok, 200, audio_data} ->
        {:ok, audio_data, "audio/mpeg"}

      {:ok, status, response_body} ->
        error_msg = extract_error_message(response_body)
        {:error, "OpenAI API error (#{status}): #{error_msg}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # ElevenLabs TTS API
  defp convert_with_elevenlabs(text, voice, api_key) do
    # Use default voice if not specified
    voice_id = voice || "21m00Tcm4TlvDq8ikWAM"  # "Rachel" voice
    url = "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}"

    body = Jason.encode!(%{
      "text" => text,
      "model_id" => "eleven_monolingual_v1"
    })

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    case http_post(url, headers, body) do
      {:ok, 200, audio_data} ->
        {:ok, audio_data, "audio/mpeg"}

      {:ok, status, response_body} ->
        error_msg = extract_error_message(response_body)
        {:error, "ElevenLabs API error (#{status}): #{error_msg}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # Simple HTTP POST using httpc (built into Erlang/OTP)
  defp http_post(url, headers, body) do
    # Ensure inets and ssl are started
    :inets.start()
    :ssl.start()

    # Convert headers to httpc format
    httpc_headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request = {
      String.to_charlist(url),
      httpc_headers,
      ~c"application/json",
      body
    }

    case :httpc.request(:post, request, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, status_code, _}, _resp_headers, resp_body}} ->
        {:ok, status_code, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      {:ok, %{"detail" => %{"message" => msg}}} -> msg
      {:ok, %{"detail" => msg}} when is_binary(msg) -> msg
      _ -> String.slice(body, 0, 200)
    end
  end

  defp extract_error_message(_), do: "Unknown error"

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
