defmodule LemonControlPlane.Methods.TtsDisable do
  @moduledoc """
  Handler for the tts.disable control plane method.

  Disables text-to-speech output.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tts.disable"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(_params, _ctx) do
    existing = LemonCore.Store.get(:tts_config, :global) || %{}

    config = Map.merge(existing, %{
      enabled: false,
      updated_at_ms: System.system_time(:millisecond)
    })

    LemonCore.Store.put(:tts_config, :global, config)

    {:ok, %{"enabled" => false}}
  end
end
