defmodule LemonControlPlane.Methods.TtsEnable do
  @moduledoc """
  Handler for the tts.enable control plane method.

  Enables text-to-speech output.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tts.enable"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    provider = params["provider"] || "system"

    existing = LemonCore.Store.get(:tts_config, :global) || %{}

    config = Map.merge(existing, %{
      enabled: true,
      provider: provider,
      updated_at_ms: System.system_time(:millisecond)
    })

    LemonCore.Store.put(:tts_config, :global, config)

    {:ok, %{
      "enabled" => true,
      "provider" => provider
    }}
  end
end
