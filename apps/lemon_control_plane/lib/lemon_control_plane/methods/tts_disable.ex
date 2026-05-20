defmodule LemonControlPlane.Methods.TtsDisable do
  @moduledoc """
  Handler for the tts.disable control plane method.

  Disables text-to-speech output.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.TtsStore

  @impl true
  def name, do: "tts.disable"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(_params, _ctx) do
    existing = TtsStore.get() || %{}

    config =
      Map.merge(existing, %{
        enabled: false,
        updated_at_ms: System.system_time(:millisecond)
      })

    TtsStore.put(config)

    {:ok,
     %{
       "enabled" => false,
       "summary" => summary(false, get_field(config, :provider))
     }}
  end

  defp summary(enabled, provider) do
    %{
      "action" => "disable",
      "enabled" => enabled,
      "provider" => provider,
      "cleanup" => %{
        "includesInputText" => false,
        "includesAudio" => false,
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
