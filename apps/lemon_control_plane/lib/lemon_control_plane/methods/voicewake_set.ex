defmodule LemonControlPlane.Methods.VoicewakeSet do
  @moduledoc """
  Handler for the voicewake.set control plane method.

  Configures voicewake (wake word detection) settings.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.Bus

  @impl true
  def name, do: "voicewake.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    enabled = params["enabled"]

    if is_nil(enabled) do
      {:error, Errors.invalid_request("enabled is required")}
    else
      existing = LemonCore.Store.get(:voicewake_config, :global) || %{}

      config = %{
        enabled: enabled,
        keyword: params["keyword"] || existing[:keyword] || "hey lemon",
        sensitivity: params["sensitivity"] || existing[:sensitivity] || 0.5,
        backend: params["backend"] || existing[:backend] || "porcupine",
        updated_at_ms: System.system_time(:millisecond)
      }

      LemonCore.Store.put(:voicewake_config, :global, config)

      # Emit voicewake.changed event
      Bus.broadcast("system", %LemonCore.Event{
        type: :voicewake_changed,
        ts_ms: System.system_time(:millisecond),
        payload: config
      })

      {:ok, %{
        "enabled" => config.enabled,
        "keyword" => config.keyword
      }}
    end
  end
end
