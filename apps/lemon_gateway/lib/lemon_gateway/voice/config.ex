defmodule LemonGateway.Voice.Config do
  @moduledoc """
  Configuration for the voice transport.
  """

  @doc """
  Returns whether the voice transport is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:lemon_gateway, :voice_enabled, false)
  end

  @doc """
  Returns the Twilio account SID.
  """
  @spec twilio_account_sid() :: String.t() | nil
  def twilio_account_sid do
    Application.get_env(:lemon_gateway, :twilio_account_sid) ||
      System.get_env("TWILIO_ACCOUNT_SID")
  end

  @doc """
  Returns the Twilio auth token.
  """
  @spec twilio_auth_token() :: String.t() | nil
  def twilio_auth_token do
    Application.get_env(:lemon_gateway, :twilio_auth_token) ||
      System.get_env("TWILIO_AUTH_TOKEN")
  end

  @doc """
  Returns the Twilio phone number for voice calls.
  """
  @spec twilio_phone_number() :: String.t() | nil
  def twilio_phone_number do
    Application.get_env(:lemon_gateway, :twilio_phone_number) ||
      System.get_env("TWILIO_PHONE_NUMBER")
  end

  @doc """
  Returns the Deepgram API key.
  """
  @spec deepgram_api_key() :: String.t() | nil
  def deepgram_api_key do
    Application.get_env(:lemon_gateway, :deepgram_api_key) ||
      System.get_env("DEEPGRAM_API_KEY")
  end

  @doc """
  Returns the ElevenLabs API key.
  """
  @spec elevenlabs_api_key() :: String.t() | nil
  def elevenlabs_api_key do
    Application.get_env(:lemon_gateway, :elevenlabs_api_key) ||
      System.get_env("ELEVENLABS_API_KEY")
  end

  @doc """
  Returns the ElevenLabs voice ID to use.
  """
  @spec elevenlabs_voice_id() :: String.t()
  def elevenlabs_voice_id do
    Application.get_env(:lemon_gateway, :elevenlabs_voice_id, "21m00Tcm4TlvDq8ikWAM")
  end

  @doc """
  Returns the WebSocket port for Twilio Media Streams.
  """
  @spec websocket_port() :: integer()
  def websocket_port do
    Application.get_env(:lemon_gateway, :voice_websocket_port, default_websocket_port())
    |> maybe_test_websocket_port()
  end

  @doc """
  Returns the public URL for Twilio webhooks.
  """
  @spec public_url() :: String.t() | nil
  def public_url do
    Application.get_env(:lemon_gateway, :voice_public_url) ||
      System.get_env("VOICE_PUBLIC_URL")
  end

  @doc """
  Returns the LLM model to use for voice responses.
  """
  @spec llm_model() :: String.t()
  def llm_model do
    Application.get_env(:lemon_gateway, :voice_llm_model, "gpt-4o-mini")
  end

  @doc """
  Returns the system prompt for voice conversations.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    Application.get_env(:lemon_gateway, :voice_system_prompt, default_system_prompt())
  end

  @doc """
  Returns the maximum duration for a voice call in seconds.
  """
  @spec max_call_duration_seconds() :: integer()
  def max_call_duration_seconds do
    Application.get_env(:lemon_gateway, :voice_max_call_duration_seconds, 600)
  end

  @doc """
  Returns the silence timeout in milliseconds.
  """
  @spec silence_timeout_ms() :: integer()
  def silence_timeout_ms do
    Application.get_env(:lemon_gateway, :voice_silence_timeout_ms, 5000)
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
end
