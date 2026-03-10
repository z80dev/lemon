defmodule LemonGateway.Voice.Config do
  @moduledoc """
  Configuration for the voice transport.

  Reads from the canonical gateway config (`[gateway.voice]` TOML section)
  via `LemonCore.GatewayConfig`.

  Temporary compatibility fallbacks to legacy app env and direct env are kept
  only where needed while tests and deployments finish migrating.
  """

  @doc """
  Returns whether the voice transport is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    voice_cfg(:enabled, Application.get_env(:lemon_gateway, :voice_enabled, false))
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
      voice_cfg(:twilio_account_sid, Application.get_env(:lemon_gateway, :twilio_account_sid)),
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
      voice_cfg(:twilio_auth_token, Application.get_env(:lemon_gateway, :twilio_auth_token)),
      "TWILIO_AUTH_TOKEN"
    )
  end

  @doc """
  Returns the Twilio phone number for voice calls.
  """
  @spec twilio_phone_number() :: String.t() | nil
  def twilio_phone_number do
    voice_cfg(:twilio_phone_number) ||
      Application.get_env(:lemon_gateway, :twilio_phone_number) ||
      System.get_env("TWILIO_PHONE_NUMBER")
  end

  @doc """
  Returns the Deepgram API key.
  """
  @spec deepgram_api_key() :: String.t() | nil
  def deepgram_api_key do
    resolve_secret(
      voice_cfg(:deepgram_api_key_secret),
      "deepgram_api_key",
      voice_cfg(:deepgram_api_key, Application.get_env(:lemon_gateway, :deepgram_api_key)),
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
      voice_cfg(:elevenlabs_api_key, Application.get_env(:lemon_gateway, :elevenlabs_api_key)),
      "ELEVENLABS_API_KEY"
    )
  end

  @doc """
  Returns the ElevenLabs voice ID to use.
  """
  @spec elevenlabs_voice_id() :: String.t()
  def elevenlabs_voice_id do
    voice_cfg(:elevenlabs_voice_id) ||
      Application.get_env(:lemon_gateway, :elevenlabs_voice_id, "21m00Tcm4TlvDq8ikWAM")
  end

  @doc """
  Returns the ElevenLabs audio output format.

  `ulaw_8000` is Twilio Media Streams compatible and avoids a conversion step.
  """
  @spec elevenlabs_output_format() :: String.t()
  def elevenlabs_output_format do
    voice_cfg(:elevenlabs_output_format) ||
      Application.get_env(:lemon_gateway, :elevenlabs_output_format, "ulaw_8000")
  end

  @doc """
  Returns the WebSocket port for Twilio Media Streams.
  """
  @spec websocket_port() :: integer()
  def websocket_port do
    port =
      voice_cfg(:websocket_port) ||
        Application.get_env(:lemon_gateway, :voice_websocket_port, default_websocket_port())

    maybe_test_websocket_port(port)
  end

  @doc """
  Returns the public URL for Twilio webhooks.
  """
  @spec public_url() :: String.t() | nil
  def public_url do
    voice_cfg(:public_url) ||
      Application.get_env(:lemon_gateway, :voice_public_url) ||
      System.get_env("VOICE_PUBLIC_URL")
  end

  @doc """
  Returns the LLM model to use for voice responses.
  """
  @spec llm_model() :: String.t()
  def llm_model do
    voice_cfg(:llm_model) ||
      Application.get_env(:lemon_gateway, :voice_llm_model, "gpt-4o-mini")
  end

  @doc """
  Returns the system prompt for voice conversations.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    voice_cfg(:system_prompt) ||
      Application.get_env(:lemon_gateway, :voice_system_prompt, default_system_prompt())
  end

  @doc """
  Returns the maximum duration for a voice call in seconds.
  """
  @spec max_call_duration_seconds() :: integer()
  def max_call_duration_seconds do
    voice_cfg(:max_call_duration_seconds) ||
      Application.get_env(:lemon_gateway, :voice_max_call_duration_seconds, 600)
  end

  @doc """
  Returns the silence timeout in milliseconds.
  """
  @spec silence_timeout_ms() :: integer()
  def silence_timeout_ms do
    voice_cfg(:silence_timeout_ms) ||
      Application.get_env(:lemon_gateway, :voice_silence_timeout_ms, 5000)
  end

  # ---------------------------------------------------------------------------
  # Canonical gateway config reader
  # ---------------------------------------------------------------------------

  defp voice_cfg(key, default \\ nil) do
    gateway = LemonCore.GatewayConfig.load()
    voice = LemonCore.GatewayConfig.fetch(gateway, :voice, %{})

    cond do
      is_map(voice) and is_atom(key) ->
        LemonCore.GatewayConfig.fetch(voice, key, nil) || default

      true ->
        default
    end
  rescue
    _ -> default
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

  defp default_websocket_port do
    if test_env?() do
      0
    else
      4047
    end
  end

  defp maybe_test_websocket_port(4047) do
    if test_env?(), do: 0, else: 4047
  end

  defp maybe_test_websocket_port(port), do: port

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  end

  defp to_bool(true, _default), do: true
  defp to_bool(false, _default), do: false
  defp to_bool(_, default), do: default

  # Resolve a secret-ref field, falling back to a named secret, plain value, then env var.
  defp resolve_secret(secret_ref, secret_name, plain_value, env_var) do
    # 1. Try explicit secret ref from config (e.g. twilio_account_sid_secret = "my_secret")
    resolved_ref =
      if is_binary(secret_ref) and secret_ref != "" do
        resolve_via_secrets(secret_ref)
      else
        nil
      end

    # 2. Try named secret (legacy pattern)
    resolved_named = resolved_ref || resolve_via_secrets(secret_name)

    # 3. Fall back to plain config value or env var
    resolved_named || plain_value || System.get_env(env_var)
  end

  defp resolve_via_secrets(name) when is_binary(name) do
    case LemonCore.Secrets.resolve(name) do
      {:ok, value, _source} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
