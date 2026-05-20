defmodule LemonControlPlane.Methods.VoicewakeSet do
  @moduledoc """
  Handler for the voicewake.set control plane method.

  Configures voicewake (wake word detection) settings.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.VoicewakeStore
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
      existing = VoicewakeStore.get() || %{}

      config = %{
        enabled: enabled,
        keyword: params["keyword"] || get_field(existing, :keyword) || "hey lemon",
        sensitivity: params["sensitivity"] || get_field(existing, :sensitivity) || 0.5,
        backend: params["backend"] || get_field(existing, :backend) || "porcupine",
        updated_at_ms: System.system_time(:millisecond)
      }

      VoicewakeStore.put(config)

      # Emit voicewake.changed event
      Bus.broadcast("system", %LemonCore.Event{
        type: :voicewake_changed,
        ts_ms: System.system_time(:millisecond),
        payload: config
      })

      {:ok,
       %{
         "enabled" => config.enabled,
         "keyword" => config.keyword,
         "sensitivity" => config.sensitivity,
         "backend" => config.backend,
         "updatedAtMs" => config.updated_at_ms,
         "summary" => summary(config)
       }}
    end
  end

  defp summary(config) do
    %{
      "enabled" => config.enabled,
      "backend" => config.backend,
      "keywordConfigured" => is_binary(config.keyword) and config.keyword != "",
      "sensitivityConfigured" => not is_nil(config.sensitivity),
      "cleanup" => %{
        "includesAudio" => false,
        "includesTranscript" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp get_field(map, key) when is_atom(key) and is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
