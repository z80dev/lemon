defmodule LemonControlPlane.Methods.TtsProviders do
  @moduledoc """
  Handler for the tts.providers control plane method.

  Returns a list of available text-to-speech providers.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tts.providers"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    providers = [
      %{
        "id" => "system",
        "name" => "System TTS",
        "description" => "Native system text-to-speech",
        "available" => true,
        "voices" => get_system_voices()
      },
      %{
        "id" => "elevenlabs",
        "name" => "ElevenLabs",
        "description" => "High-quality AI voice synthesis",
        "available" => elevenlabs_available?(),
        "voices" => []
      },
      %{
        "id" => "openai",
        "name" => "OpenAI TTS",
        "description" => "OpenAI text-to-speech API",
        "available" => openai_tts_available?(),
        "voices" => ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
      }
    ]

    {:ok, %{"providers" => providers}}
  end

  defp get_system_voices do
    # Return empty list as voice discovery is platform-specific
    []
  end

  defp elevenlabs_available? do
    # Check if ElevenLabs API key is configured
    not is_nil(Application.get_env(:lemon_control_plane, :elevenlabs_api_key))
  end

  defp openai_tts_available? do
    # Check if OpenAI API key is configured
    not is_nil(Application.get_env(:lemon_control_plane, :openai_api_key))
  end
end
