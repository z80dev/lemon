defmodule LemonChannels.VoiceReply do
  @moduledoc """
  Synthesizes an already-delivered text reply and records its actual usage.

  Callers own opt-in/inbound-voice gating and must always deliver the transcript
  independently. Configuration is the channel's resolved `voice_replies` map.
  Context carries `run_id`, `session_key`, `agent_id` and optional `delivery_id`.
  `provider_module`, `http_client` and `usage_recorder` are injectable test seams;
  the recorder accepts one `LemonCore.UsageLedger` entry. When provider cost is
  absent, configured model pricing estimates cost from input characters.
  Unknown speech pricing is recorded as nil, never zero.

  Audio is limited to 20 MiB both while receiving the HTTP response and before
  recording usage or returning provider output to the delivery caller.
  """

  require Logger

  @max_audio_bytes 20 * 1024 * 1024

  @doc "Maximum encoded audio size accepted from any speech provider."
  def max_audio_bytes, do: @max_audio_bytes

  @spec synthesize(binary(), map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(text, config, context)
      when is_binary(text) and is_map(config) and is_map(context) do
    provider = Map.get(context, :provider_module, LemonChannels.OpenAIVoiceProvider)

    cond do
      String.trim(text) == "" ->
        {:error, :empty_text}

      config[:provider] not in ["openai", "openai_speech"] ->
        {:error, :unsupported_provider}

      true ->
        with {:ok, config} <- resolve_credentials(config),
             {:ok, audio} <- provider.synthesize(text, config, context),
             :ok <- validate_audio(audio) do
          record_usage(text, config, context, audio)
          {:ok, Map.take(audio, [:audio_bytes, :mime_type, :filename])}
        end
    end
  rescue
    _ -> {:error, :speech_synthesis_failed}
  catch
    :exit, _ -> {:error, :speech_synthesis_failed}
  end

  def synthesize(_, _, _), do: {:error, :invalid_speech_request}

  defp validate_audio(%{audio_bytes: bytes})
       when is_binary(bytes) and byte_size(bytes) > @max_audio_bytes,
       do: {:error, :audio_too_large}

  defp validate_audio(%{audio_bytes: bytes, mime_type: mime, filename: filename})
       when is_binary(bytes) and byte_size(bytes) > 0 and is_binary(mime) and is_binary(filename),
       do: :ok

  defp validate_audio(_), do: {:error, :invalid_audio}

  defp resolve_credentials(%{api_key_secret: secret} = config)
       when is_binary(secret) and secret != "" do
    case LemonCore.Secrets.resolve(secret, env_fallback: true) do
      {:ok, key, _source} when is_binary(key) and key != "" ->
        {:ok, Map.put(config, :api_key, key)}

      _ ->
        {:error, :speech_credentials_unavailable}
    end
  end

  defp resolve_credentials(config), do: {:ok, config}

  defp record_usage(text, config, context, audio) do
    usage = Map.get(audio, :usage, %{})
    reported_cost = Map.get(usage, :cost_usd)
    characters = String.length(text)

    cost =
      cond do
        is_number(reported_cost) and reported_cost >= 0 ->
          reported_cost

        is_number(config[:price_per_million_characters]) and
            config[:price_per_million_characters] >= 0 ->
          characters * config[:price_per_million_characters] / 1_000_000

        true ->
          nil
      end

    input = tokens(usage[:input_tokens])
    output = tokens(usage[:output_tokens])
    delivery_id = context[:delivery_id] || Base.encode16(:crypto.hash(:sha256, text))

    entry = %{
      run_id: context[:run_id],
      session_key: context[:session_key],
      agent_id: context[:agent_id],
      occurrence: "voice_reply:" <> to_string(delivery_id),
      at_ms: System.system_time(:millisecond),
      provider: "openai",
      model: config[:model] || "gpt-4o-mini-tts",
      input: input,
      output: output,
      total_tokens: input + output,
      input_characters: characters,
      cost: cost,
      price_known: not is_nil(cost)
    }

    recorder = Map.get(context, :usage_recorder, &LemonCore.UsageLedger.record/1)

    case recorder.(entry) do
      :ok -> :ok
      _ -> Logger.warning("Voice reply usage recording failed")
    end
  rescue
    _ -> Logger.warning("Voice reply usage recording failed")
  catch
    :exit, _ -> Logger.warning("Voice reply usage recording failed")
  end

  defp tokens(value) when is_integer(value) and value >= 0, do: value
  defp tokens(_), do: 0
end
