defmodule LemonControlPlane.Methods.NodePairInviteRevoke do
  @moduledoc "Revokes a pending unused invitation without changing an established node."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.invite.revoke"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, ctx) do
    invite_id = params["inviteId"]

    with :ok <- Authorize.authorize(ctx[:auth] || %{}, name(), scopes()),
         true <- is_binary(invite_id) and byte_size(invite_id) in 1..128 do
      case NodeStore.revoke_invite(invite_id) do
        :ok -> {:ok, %{"inviteId" => invite_id, "revoked" => true}}
        {:error, :not_found} -> {:error, Errors.not_found("Pending invitation was not found")}
        {:error, _} -> {:error, Errors.unavailable("Enrollment invite store is unavailable")}
      end
    else
      false -> {:error, Errors.invalid_request("inviteId is required")}
      {:error, _} = error -> error
    end
  end
end
