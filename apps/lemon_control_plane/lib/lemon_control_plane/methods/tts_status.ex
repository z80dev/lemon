defmodule LemonControlPlane.Methods.TtsStatus do
  @moduledoc """
  Handler for the tts.status control plane method.

  Returns the current text-to-speech configuration and status.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.TtsStore
  alias LemonControlPlane.Methods.TtsProviders

  @impl true
  def name, do: "tts.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    stored_config = TtsStore.get()
    config = stored_config || default_config()
    enabled = get_field(config, :enabled) || false
    provider = get_field(config, :provider) || "system"
    voice = get_field(config, :voice, nil)
    rate = get_field(config, :rate) || 1.0
    updated_at_ms = get_field(config, :updated_at_ms, nil)
    providers = provider_statuses()
    provider_status = Enum.find(providers, &(&1["id"] == provider))
    known_provider = not is_nil(provider_status)
    provider_available = known_provider and Map.get(provider_status, "available") == true

    {:ok,
     %{
       "enabled" => enabled,
       "provider" => provider,
       "voice" => voice,
       "rate" => rate,
       "updatedAtMs" => updated_at_ms,
       "configured" => not is_nil(stored_config),
       "knownProvider" => known_provider,
       "providerAvailable" => provider_available,
       "providers" => providers,
       "summary" =>
         summary(%{
           enabled: enabled,
           configured: not is_nil(stored_config),
           known_provider: known_provider,
           provider_available: provider_available,
           providers: providers
         }),
       "includesSecretValues" => false,
       "includesRawKeyMaterial" => false,
       "includesRawProviderErrors" => false
     }}
  end

  defp default_config do
    %{
      enabled: false,
      provider: "system",
      voice: nil,
      rate: 1.0
    }
  end

  defp provider_statuses do
    case TtsProviders.handle(%{}, %{}) do
      {:ok, %{"providers" => providers}} when is_list(providers) ->
        Enum.map(providers, &safe_provider_status/1)

      _ ->
        []
    end
  end

  defp safe_provider_status(provider) when is_map(provider) do
    %{
      "id" => Map.get(provider, "id"),
      "name" => Map.get(provider, "name"),
      "available" => Map.get(provider, "available") == true,
      "voiceCount" => voice_count(Map.get(provider, "voices"))
    }
  end

  defp voice_count(voices) when is_list(voices), do: length(voices)
  defp voice_count(_voices), do: 0

  defp summary(state) do
    providers = state.providers

    status =
      cond do
        state.enabled == false -> "disabled"
        state.known_provider == false -> "unknown_provider"
        state.provider_available == false -> "provider_unavailable"
        true -> "ready"
      end

    %{
      "status" => status,
      "configured" => state.configured,
      "enabled" => state.enabled == true,
      "knownProvider" => state.known_provider,
      "providerAvailable" => state.provider_available,
      "knownProviderCount" => length(providers),
      "availableProviderCount" => Enum.count(providers, &(&1["available"] == true)),
      "unavailableProviderCount" => Enum.count(providers, &(&1["available"] == false))
    }
  end

  defp get_field(map, key, default \\ nil)

  defp get_field(map, key, _default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
