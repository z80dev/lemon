defmodule LemonControlPlane.Methods.NodeDescribe do
  @moduledoc """
  Handler for the node.describe control plane method.

  Gets detailed information about a specific node.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.describe"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"] || params["node_id"]

    if is_nil(node_id) or node_id == "" do
      {:error, Errors.invalid_request("nodeId is required")}
    else
      case NodeStore.get_node(node_id) do
        nil ->
          {:error, Errors.not_found("Node not found")}

        node ->
          payload = format_node(node)

          {:ok, Map.put(payload, "summary", summary(payload))}
      end
    end
  end

  defp format_node(node) do
    %{
      "nodeId" => get_field(node, :id),
      "name" => get_field(node, :name),
      "type" => get_field(node, :type),
      "capabilities" => get_field(node, :capabilities) || %{},
      "status" => to_string(get_field(node, :status) || :unknown),
      "pairedAtMs" => get_field(node, :paired_at_ms),
      "lastSeenMs" => get_field(node, :last_seen_ms),
      "metadata" => redact_metadata(get_field(node, :metadata) || %{})
    }
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp summary(node) do
    %{
      "status" => node["status"],
      "type" => node["type"],
      "capabilityCount" => map_size(node["capabilities"] || %{}),
      "metadataKeyCount" => map_size(node["metadata"] || %{}),
      "cleanup" => %{
        "includesCapabilities" => true,
        "includesMetadata" => true,
        "redactsMetadataSecretKeys" => true,
        "includesInvocationResults" => false,
        "includesPairingSecrets" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp redact_metadata(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      string_key = to_string(key)

      if sensitive_key?(string_key) do
        {string_key, %{"redacted" => true, "kind" => "secret"}}
      else
        {string_key, redact_metadata(value)}
      end
    end)
  end

  defp redact_metadata(list) when is_list(list), do: Enum.map(list, &redact_metadata/1)
  defp redact_metadata(value), do: value

  defp sensitive_key?(key) do
    normalized = String.downcase(key)

    Enum.any?(["token", "secret", "password", "api_key", "apikey", "credential", "cookie"], fn
      marker -> String.contains?(normalized, marker)
    end)
  end
end
