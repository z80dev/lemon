defmodule LemonControlPlane.Methods.ProvidersStatus do
  @moduledoc """
  Handler for `providers.status`.

  Returns redacted provider credential readiness and config-shape metadata for
  operator setup and diagnostics.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "providers.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    status = LemonAiRuntime.ProviderStatus.snapshot(params || %{})
    {:ok, Map.put(status, "summary", summary(status))}
  rescue
    error ->
      {:error,
       {
         :internal_error,
         "Failed to build provider status",
         Exception.message(error)
       }}
  end

  defp summary(status) do
    routing = Map.get(status, "routing", %{})
    live_proofs = Map.get(status, "liveProofs", %{})
    fallback = Map.get(live_proofs, "fallback", %{})

    %{
      "action" => name(),
      "providerCount" => Map.get(status, "count", 0),
      "readyProviderCount" => Map.get(status, "readyCount", 0),
      "defaultProviderConfigured" => present?(Map.get(status, "defaultProvider")),
      "defaultModelConfigured" => present?(Map.get(status, "defaultModel")),
      "selectedProvider" => Map.get(routing, "selectedProvider"),
      "routingDecision" => Map.get(routing, "decision"),
      "fallbackProofStatus" => Map.get(fallback, "status"),
      "liveProofScopeCount" => map_size(Map.get(live_proofs, "proofScopeCounts", %{})),
      "cleanup" => Map.get(status, "cleanup", %{})
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
