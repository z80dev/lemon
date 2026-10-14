defmodule LemonControlPlane.Methods.ProfilesSync do
  @moduledoc """
  Provisions a credential-free persona on an execution node without moving it.

  An explicit durable node ID allows provisioning before changing placement.
  Otherwise the profile's current named node must resolve uniquely. Local
  profiles require an explicit target. Success is returned only for an exact
  destination acknowledgement of profile, mutation and canonical revision.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.{NodeIO, NodeStore}
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{ProfileSnapshot, ProfileStore}

  @impl true
  def name, do: "profiles.sync"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, %{auth: %{role: :operator} = auth} = ctx) when is_map(params) do
    with :ok <- Authorize.authorize(auth, name(), scopes()),
         :ok <- validate_params(params),
         {:ok, profile} <- ProfileStore.get(params["id"]),
         {:ok, node_id} <- target_node(params, profile),
         {:ok, persona} <- ProfileStore.persona_snapshot(params["id"]),
         {:ok, payload} <- ProfileSnapshot.build(persona, params["mutationId"]),
         {:ok, ack} <- invoke(node_id, payload, ctx),
         :ok <- validate_ack(ack, payload) do
      {:ok,
       payload
       |> Map.take(~w(profileId mutationId revisionDigest))
       |> Map.merge(%{"nodeId" => node_id, "acknowledged" => true})}
    else
      {:error, reason} -> error(reason)
      _ -> error(:sync_failed)
    end
  rescue
    _ -> error(:sync_failed)
  catch
    _, _ -> error(:sync_failed)
  end

  def handle(_params, _ctx),
    do: {:error, Errors.forbidden("Profile sync requires operator administrator access")}

  defp validate_params(params) do
    if Enum.all?(Map.keys(params), &(&1 in ~w(id nodeId mutationId))) and
         ProfileSnapshot.valid_mutation?(params["mutationId"]) and
         (not Map.has_key?(params, "nodeId") or valid_node_id?(params["nodeId"])) do
      :ok
    else
      {:error, :invalid_sync_request}
    end
  end

  defp target_node(%{"nodeId" => node_id}, _profile), do: {:ok, node_id}

  defp target_node(_params, %{"node" => node}) when node in [nil, "local"],
    do: {:error, :target_required}

  defp target_node(_params, profile) do
    case NodeStore.get_node(profile["node"]) do
      nil ->
        matching =
          Enum.filter(NodeStore.list_nodes(), fn {_id, node} ->
            (Map.get(node, :name) || Map.get(node, "name")) == profile["node"]
          end)

        case matching do
          [{id, _}] -> {:ok, id}
          [] -> {:error, :target_unavailable}
          _ -> {:error, :ambiguous_target}
        end

      _stored_node ->
        # Stored identity is authoritative even while offline. A same-named
        # connection must never receive another node's private persona.
        {:ok, profile["node"]}
    end
  end

  defp valid_node_id?(id) when is_binary(id),
    do: byte_size(id) in 1..128 and String.valid?(id) and String.trim(id) == id

  defp valid_node_id?(_), do: false

  defp invoke(node_id, payload, ctx) do
    case NodeIO.invoke(node_id, "node.profile.sync", payload, ctx) do
      {:ok, ack} ->
        {:ok, ack}

      {:error, {_code, _message, %{"reason" => "mutation_conflict"}}} ->
        {:error, :mutation_conflict}

      {:error, _} ->
        {:error, :destination_unavailable}
    end
  end

  defp validate_ack(ack, payload) when is_map(ack) do
    if ack["acknowledged"] == true and
         Enum.all?(~w(profileId mutationId revisionDigest), fn key ->
           Map.has_key?(ack, key) and ack[key] == payload[key]
         end),
       do: :ok,
       else: {:error, :invalid_ack}
  end

  defp validate_ack(_, _), do: {:error, :invalid_ack}

  defp error({:forbidden, _} = reason), do: {:error, reason}
  defp error(:not_found), do: {:error, Errors.error(:not_found, "Profile not found")}

  defp error(:target_required),
    do: {:error, Errors.invalid_request("Profile sync requires nodeId for a local profile")}

  defp error(:ambiguous_target),
    do: {:error, Errors.error(:conflict, "Profile sync target is ambiguous")}

  defp error(:mutation_conflict),
    do: {:error, Errors.error(:conflict, "Profile sync mutation conflicts with its revision")}

  defp error(reason)
       when reason in [:invalid_id, :invalid_sync_request, :invalid_profile_snapshot],
       do: {:error, Errors.invalid_request("Profile sync request is invalid")}

  defp error(reason) do
    classification =
      case reason do
        :invalid_ack -> "invalid_acknowledgement"
        :target_unavailable -> "target_unavailable"
        _ -> "sync_unavailable"
      end

    {:error,
     Errors.error(:unavailable, "Profile sync was not acknowledged", %{
       "reason" => classification,
       "retrySafe" => false
     })}
  end
end
