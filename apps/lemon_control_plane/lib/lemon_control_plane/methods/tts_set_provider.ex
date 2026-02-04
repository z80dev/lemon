defmodule LemonControlPlane.Methods.TtsSetProvider do
  @moduledoc """
  Handler for the tts.set-provider control plane method.

  Sets the active TTS provider.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @valid_providers ~w(system openai elevenlabs)

  @impl true
  def name, do: "tts.set-provider"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    provider = params["provider"]

    if is_nil(provider) or provider == "" do
      {:error, Errors.invalid_request("provider is required")}
    else
      if provider not in @valid_providers do
        {:error, Errors.invalid_request("Invalid provider. Valid options: #{Enum.join(@valid_providers, ", ")}")}
      else
        existing = LemonCore.Store.get(:tts_config, :global) || %{}

        config = Map.merge(existing, %{
          provider: provider,
          updated_at_ms: System.system_time(:millisecond)
        })

        LemonCore.Store.put(:tts_config, :global, config)

        {:ok, %{"provider" => provider}}
      end
    end
  end
end
