defmodule LemonControlPlane.Methods.VoicewakeGet do
  @moduledoc """
  Handler for the voicewake.get control plane method.

  Returns the current voicewake (wake word detection) configuration.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.VoicewakeStore

  @impl true
  def name, do: "voicewake.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    stored_config = VoicewakeStore.get()
    config = stored_config || default_config()
    enabled = get_field(config, :enabled) || false
    keyword = get_field(config, :keyword) || "hey lemon"
    sensitivity = get_field(config, :sensitivity) || 0.5
    backend = get_field(config, :backend) || "porcupine"
    updated_at_ms = get_field(config, :updated_at_ms)

    {:ok,
     %{
       "enabled" => enabled,
       "keyword" => keyword,
       "sensitivity" => sensitivity,
       "backend" => backend,
       "updatedAtMs" => updated_at_ms,
       "configured" => not is_nil(stored_config),
       "summary" => %{
         "status" => if(enabled == true, do: "enabled", else: "disabled"),
         "backend" => backend,
         "configured" => not is_nil(stored_config)
       },
       "includesAudioSamples" => false,
       "includesSecretValues" => false
     }}
  end

  defp default_config do
    %{
      enabled: false,
      keyword: "hey lemon",
      sensitivity: 0.5,
      backend: "porcupine"
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
