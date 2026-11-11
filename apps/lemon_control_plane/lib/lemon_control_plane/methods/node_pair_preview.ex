defmodule LemonControlPlane.Methods.NodePairPreview do
  @moduledoc "Projects invite controller reachability without issuing an enrollment credential."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.NodePairInvite

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

      {:ok, %{"reachability" => reachability}}
    end
  end
end
