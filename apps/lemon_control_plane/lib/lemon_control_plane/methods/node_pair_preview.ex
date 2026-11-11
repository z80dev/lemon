defmodule LemonControlPlane.Methods.NodePairPreview do
  @moduledoc """
  Projects invite controller reachability and node gateway availability without
  issuing an enrollment credential. Gateway addresses are not exposed.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.NodePairInvite
  alias LemonControlPlane.NodeGateway

  @impl true
  def name, do: "node.pair.preview"
  @impl true
  def scopes, do: NodePairInvite.scopes()

  @impl true
  def handle(_params, ctx) do
    with :ok <- Authorize.authorize(ctx[:auth] || %{}, name(), scopes()),
         {:ok, controller} <- NodePairInvite.controller_url() do
      reachability =
        if URI.parse(controller).host in ["localhost", "127.0.0.1", "::1"],
          do: "loopback_only",
          else: "routable"

      gateway = NodeGateway.status()

      {:ok,
       %{
         "reachability" => reachability,
         "nodeGateway" => %{"available" => gateway.available, "port" => gateway.port}
       }}
    end
  end
end
