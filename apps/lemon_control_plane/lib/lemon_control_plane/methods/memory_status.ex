defmodule LemonControlPlane.Methods.MemoryStatus do
  @moduledoc """
  Handler for `memory.status`.

  Returns redacted metadata for registered memory providers. It does not expose
  memory document contents, prompts, tool output, or raw provider config.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "memory.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    status = LemonCore.MemoryProviders.status()
    providers = Enum.map(Map.get(status, :providers, []), &format_provider/1)

    {:ok,
     %{
       "providerCount" => Map.get(status, :provider_count, 0),
       "enabledProviderCount" => Map.get(status, :enabled_provider_count, 0),
       "providers" => providers,
       "health" => format_health(providers),
       "cleanup" => format_cleanup(Map.get(status, :cleanup, %{}))
     }}
    |> put_summary()
  rescue
    error ->
      {:error,
       {
         :internal_error,
         "Failed to build memory status",
         Exception.message(error)
       }}
  end

  defp format_provider(provider) when is_map(provider) do
    %{
      "id" => Map.get(provider, :id),
      "enabled" => Map.get(provider, :enabled) == true,
      "source" => Map.get(provider, :source),
      "scopes" => Map.get(provider, :scopes, []),
      "timeoutMs" => Map.get(provider, :timeout_ms),
      "moduleLoaded" => Map.get(provider, :module_loaded) == true
    }
  end

  defp format_provider(_), do: %{}

  defp format_health(providers) do
    enabled = Enum.filter(providers, &(&1["enabled"] == true))
    module_loaded = Enum.filter(providers, &(&1["moduleLoaded"] == true))

    %{
      "status" => health_status(providers),
      "enabledCount" => length(enabled),
      "disabledCount" => Enum.count(providers, &(&1["enabled"] != true)),
      "moduleLoadedCount" => length(module_loaded),
      "moduleMissingCount" => Enum.count(providers, &(&1["moduleLoaded"] != true)),
      "searchableScopes" => searchable_scopes(enabled),
      "scopeCounts" => scope_counts(enabled)
    }
  end

  defp health_status([]), do: "missing"

  defp health_status(providers) do
    cond do
      Enum.any?(providers, &(&1["enabled"] == true and &1["moduleLoaded"] == true)) -> "ready"
      Enum.any?(providers, &(&1["enabled"] == true)) -> "degraded"
      true -> "disabled"
    end
  end

  defp searchable_scopes(providers) do
    providers
    |> Enum.flat_map(&List.wrap(&1["scopes"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scope_counts(providers) do
    providers
    |> Enum.flat_map(&List.wrap(&1["scopes"]))
    |> Enum.frequencies()
    |> Map.new(fn {scope, count} -> {to_string(scope), count} end)
  end

  defp format_cleanup(cleanup) when is_map(cleanup) do
    %{
      "includesMemoryContents" => Map.get(cleanup, :includes_memory_contents, false),
      "includesRawProviderConfig" => Map.get(cleanup, :includes_raw_provider_config, false),
      "includesSecretValues" => Map.get(cleanup, :includes_secret_values, false)
    }
  end

  defp format_cleanup(_), do: format_cleanup(%{})

  defp put_summary({:ok, payload}) do
    {:ok,
     Map.put(payload, "summary", %{
       "action" => "memory.status",
       "providerCount" => payload["providerCount"],
       "enabledProviderCount" => payload["enabledProviderCount"],
       "healthStatus" => payload["health"]["status"],
       "searchableScopeCount" => length(payload["health"]["searchableScopes"] || []),
       "cleanup" => payload["cleanup"]
     })}
  end
end
