defmodule LemonControlPlane.Methods.ProvidersConfigure do
  @moduledoc """
  Admin mutation surface for provider fallbacks and credential-pool references.

  The shared model-runtime service owns validation, confirmation, comment-aware
  TOML editing, atomic replacement, and redaction. This method only maps that
  stable result into the JSON-RPC error contract.
  """

  @behaviour LemonControlPlane.Method

  alias LemonAgent.ModelRuntime.ProviderConfiguration

  @impl true
  def name, do: "providers.configure"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    case ProviderConfiguration.configure(params || %{}) do
      {:ok, result} ->
        {:ok, Map.put(result, "summary", summary(result))}

      {:error, code, message} ->
        {:error, {rpc_code(code), message, %{"code" => Atom.to_string(code)}}}
    end
  end

  defp summary(result) do
    routing =
      Map.get(result, "proposedRoutingConfig") || Map.get(result, "routingConfig", %{})

    %{
      "action" => name(),
      "operation" => Map.get(result, "action"),
      "applied" => Map.get(result, "applied") == true,
      "changed" => Map.get(result, "changed") == true,
      "destructive" => Map.get(result, "destructive") == true,
      "targetScope" => Map.get(result, "targetScope"),
      "fallbackProviderCount" => length(Map.get(routing, "fallbackProviders", [])),
      "credentialPoolCount" => Map.get(routing, "credentialPoolCount", 0),
      "credentialReferenceCount" => Map.get(routing, "credentialReferenceCount", 0),
      "cleanup" => Map.get(result, "cleanup", %{})
    }
  end

  defp rpc_code(code)
       when code in [
              :invalid_action,
              :invalid_config,
              :invalid_credential_reference,
              :invalid_name,
              :invalid_provider,
              :invalid_providers,
              :invalid_scope,
              :invalid_strategy,
              :missing_parameter
            ],
       do: :invalid_request

  defp rpc_code(:confirmation_required), do: :conflict
  defp rpc_code(_), do: :internal_error
end
