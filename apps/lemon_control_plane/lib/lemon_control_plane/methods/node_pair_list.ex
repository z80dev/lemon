defmodule LemonControlPlane.Methods.NodePairList do
  @moduledoc """
  Handler for the node.pair.list control plane method.

  Lists pending pairing requests.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore

  @impl true
  def name, do: "node.pair.list"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(_params, _ctx) do
    now = System.system_time(:millisecond)

    requests =
      NodeStore.list_pairings()
      |> Enum.map(fn {_id, request} -> request end)
      |> Enum.filter(fn request ->
        status = get_field(request, :status)
        expires_at_ms = get_field(request, :expires_at_ms)

        pending?(status) and (is_nil(expires_at_ms) or expires_at_ms > now)
      end)
      |> Enum.map(&format_request/1)

    {:ok, %{"requests" => requests, "summary" => summary(requests)}}
  end

  defp format_request(request) do
    %{
      "pairingId" => get_field(request, :id),
      "code" => get_field(request, :code),
      "nodeType" => get_field(request, :node_type),
      "nodeName" => get_field(request, :node_name),
      "capabilities" => get_field(request, :capabilities) || %{},
      "expiresAtMs" => get_field(request, :expires_at_ms),
      "createdAtMs" => get_field(request, :created_at_ms)
    }
  end

  defp pending?(:pending), do: true
  defp pending?("pending"), do: true
  defp pending?(_), do: false

  defp summary(requests) do
    %{
      "pendingCount" => length(requests),
      "nodeTypeCounts" => count_by(requests, "nodeType"),
      "capabilityCounts" => capability_counts(requests),
      "cleanup" => %{
        "includesPairingCodes" => true,
        "includesCapabilities" => true,
        "includesApprovedTokens" => false,
        "includesChallengeTokens" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp count_by(requests, key) do
    requests
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp capability_counts(requests) do
    requests
    |> Enum.flat_map(fn request ->
      request
      |> Map.get("capabilities", %{})
      |> Map.keys()
    end)
    |> Enum.map(&to_string/1)
    |> Enum.frequencies()
  end

  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
