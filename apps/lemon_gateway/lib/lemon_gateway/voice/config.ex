defmodule LemonGateway.Voice.Config do
  @moduledoc """
  Configuration for the voice transport.

  Reads from the canonical gateway config (`[gateway.voice]` TOML section)
  via `LemonCore.GatewayConfig`.

  Credentials may also come from the secret store or their documented
  environment variables; there is no application-env fallback.
  """

  require Logger

  @doc """
  Returns whether the voice transport is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    voice_cfg(:enabled, false)
    |> to_bool(false)
  end

  @doc """
  Returns the Twilio account SID.
  """
  @spec twilio_account_sid() :: String.t() | nil
  def twilio_account_sid do
    resolve_secret(
      voice_cfg(:twilio_account_sid_secret),
      "twilio_account_sid",
      voice_cfg(:twilio_account_sid),
      "TWILIO_ACCOUNT_SID"
    )
  end

  @doc """
  Returns the Twilio auth token.
  """
  @spec twilio_auth_token() :: String.t() | nil
  def twilio_auth_token do
    resolve_secret(
      voice_cfg(:twilio_auth_token_secret),
      "twilio_auth_token",
      voice_cfg(:twilio_auth_token),
      "TWILIO_AUTH_TOKEN"
    )
  end

  @doc """
  Returns the Twilio phone number for voice calls.
  """
  @spec twilio_phone_number() :: String.t() | nil
  def twilio_phone_number do
    voice_cfg(:twilio_phone_number) || System.get_env("TWILIO_PHONE_NUMBER")
  end

  @doc """
  Returns the Deepgram API key.
  """
  @spec deepgram_api_key() :: String.t() | nil
  def deepgram_api_key do
    resolve_secret(
      voice_cfg(:deepgram_api_key_secret),
      "deepgram_api_key",
      voice_cfg(:deepgram_api_key),
      "DEEPGRAM_API_KEY"
    )
  end

  @doc """
  Returns the ElevenLabs API key.
  """
  @spec elevenlabs_api_key() :: String.t() | nil
  def elevenlabs_api_key do
    resolve_secret(
      voice_cfg(:elevenlabs_api_key_secret),
      "elevenlabs_api_key",
      voice_cfg(:elevenlabs_api_key),
      "ELEVENLABS_API_KEY"
    )
  end

  @doc """
  Returns the ElevenLabs voice ID to use.
  """
  @spec elevenlabs_voice_id() :: String.t()
  def elevenlabs_voice_id do
    voice_cfg(:elevenlabs_voice_id, "21m00Tcm4TlvDq8ikWAM")
  end

  @doc """
  Returns the ElevenLabs audio output format.

  `ulaw_8000` is Twilio Media Streams compatible and avoids a conversion step.
  """
  @spec elevenlabs_output_format() :: String.t()
  def elevenlabs_output_format do
    voice_cfg(:elevenlabs_output_format, "ulaw_8000")
  end

  @doc """
  Returns the WebSocket port for Twilio Media Streams.
  """
  @spec websocket_port() :: integer()
  def websocket_port do
    voice_cfg(:websocket_port, 4047)
  end

  @doc """
  Returns the public URL for Twilio webhooks.
  """
  @spec public_url() :: String.t() | nil
  def public_url do
    voice_cfg(:public_url) || System.get_env("VOICE_PUBLIC_URL")
  end

  @doc """
  Returns the LLM model to use for voice responses.
  """
  @spec llm_model() :: String.t()
  def llm_model do
    voice_cfg(:llm_model, "gpt-4o-mini")
  end

  @doc """
  Returns the system prompt for voice conversations.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    voice_cfg(:system_prompt) || default_system_prompt()
  end

  @doc """
  Returns the maximum duration for a voice call in seconds.
  """
  @spec max_call_duration_seconds() :: integer()
  def max_call_duration_seconds do
    voice_cfg(:max_call_duration_seconds, 600)
  end

  @doc """
  Returns the silence timeout in milliseconds.
  """
  @spec silence_timeout_ms() :: integer()
  def silence_timeout_ms do
    voice_cfg(:silence_timeout_ms, 5000)
  end

  # ---------------------------------------------------------------------------
  # Canonical gateway config reader
  # ---------------------------------------------------------------------------

  defp voice_cfg(key, default \\ nil) do
    gateway = LemonCore.GatewayConfig.load()
    voice = LemonCore.GatewayConfig.fetch(gateway, :voice, %{})

    # Fall back only when the key is missing or nil: an explicit `false`
    # (e.g. `enabled = false`) must not be overridden by the default.
    with true <- is_map(voice) and is_atom(key),
         value when not is_nil(value) <- LemonCore.GatewayConfig.fetch(voice, key, nil) do
      value
    else
      _ -> default
    end
  end

  defp default_system_prompt do
    """
    You are zeebot, a friendly AI assistant built on the Lemon framework. You're talking to someone on the phone.

    Guidelines:
    - Keep responses concise (1-3 sentences max) — this is a voice conversation
    - Be warm, helpful, and occasionally witty
    - If you need to perform actions, do so efficiently
    - If you don't know something, say so honestly
    - Remember: the user is listening, not reading

    You can help with:
    - Answering questions
    - Performing tasks via tools
    - Having casual conversation
    """
  end

  defp to_bool(true, _default), do: true
  defp to_bool(false, _default), do: false
  defp to_bool(_, default), do: default

  # Resolve a secret-ref field, falling back to a named secret, plain value, then env var.
  # Only a definite miss advances to the next candidate: an unreadable secret
  # (decrypt failure, corrupt record, store/external error) yields nil so callers
  # never silently authenticate with a plaintext/env credential instead.
  defp resolve_secret(secret_ref, secret_name, plain_value, env_var) do
    candidates =
      if is_binary(secret_ref) and secret_ref != "",
        do: [secret_ref, secret_name],
        else: [secret_name]

    case resolve_first_secret(candidates) do
      {:ok, value} -> value
      :not_found -> plain_value || System.get_env(env_var)
      :error -> nil
    end
  end

  defp resolve_first_secret([]), do: :not_found

  defp resolve_first_secret([name | rest]) do
    case resolve_via_secrets(name) do
      {:ok, value, _source} ->
        {:ok, value}

      {:error, :not_found} ->
        resolve_first_secret(rest)

      {:error, reason} ->
        Logger.warning("Voice secret #{inspect(name)} is unreadable: #{inspect(reason)}")
        :error
    end
  end

  defp resolve_via_secrets(name) do
    LemonCore.Secrets.resolve(name)
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
