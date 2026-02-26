defmodule LemonControlPlane.Methods.NodePairList do
  @moduledoc """
  Handler for the node.pair.list control plane method.

  Lists pending pairing requests.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "node.pair.list"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(_params, _ctx) do
    now = System.system_time(:millisecond)

    # Get all pairing requests
    requests =
      LemonCore.Store.list(:nodes_pairing)
      |> Enum.map(fn {_id, request} -> request end)
      |> Enum.filter(fn request ->
        # Only pending and not expired
        request[:status] == :pending and
          (is_nil(request[:expires_at_ms]) or request[:expires_at_ms] > now)
      end)
      |> Enum.map(&format_request/1)

    {:ok, %{"requests" => requests}}
  end

  defp format_request(request) do
    %{
      "pairingId" => request[:id],
      "code" => request[:code],
      "nodeType" => request[:node_type],
      "nodeName" => request[:node_name],
      "capabilities" => request[:capabilities] || %{},
      "expiresAtMs" => request[:expires_at_ms],
      "createdAtMs" => request[:created_at_ms]
    }
  end
end
