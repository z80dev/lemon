defmodule LemonControlPlane.Methods.TtsEnable do
  @moduledoc """
  Handler for the tts.enable control plane method.

  Enables text-to-speech output.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.TtsStore

  @impl true
  def name, do: "tts.enable"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    provider = params["provider"] || "system"

    existing = TtsStore.get() || %{}

    config =
      Map.merge(existing, %{
        enabled: true,
        provider: provider,
        updated_at_ms: System.system_time(:millisecond)
      })

    TtsStore.put(config)

    {:ok,
     %{
       "enabled" => true,
       "provider" => provider
     }}
  end
end
