defmodule LemonControlPlane.Methods.ProfilesSyncStatus do
  @moduledoc """
  Reads a destination's latest retained persona-sync receipt without replaying it.

  The lookup binds the exact durable node ID, profile ID, non-null mutation ID and
  current source persona revision. Only those correlation fields cross the wire;
  persona text is not resent. A missing/superseded binding is unknown, whereas
  transport, persistence or acknowledgement failures remain unavailable.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.NodeIO
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{ProfileSnapshot, ProfileStore}

  @fields ~w(profileId mutationId status acknowledged revisionDigest)

  @impl true
  def name, do: "profiles.sync.status"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, %{auth: %{role: :operator} = auth} = ctx) when is_map(params) do
    with :ok <- Authorize.authorize(auth, name(), scopes()),
         :ok <- validate_params(params),
         {:ok, persona} <- ProfileStore.persona_snapshot(params["id"]),
         {:ok, snapshot} <- ProfileSnapshot.build(persona, params["mutationId"]),
         request <- Map.take(snapshot, ~w(profileId mutationId revisionDigest)),
         {:ok, receipt} <-
           NodeIO.invoke(params["nodeId"], "node.profile.sync.status", request, ctx),
         :ok <- validate_receipt(receipt, request) do
      {:ok, Map.take(receipt, @fields) |> Map.put("nodeId", params["nodeId"])}
    else
      {:error, reason} -> error(reason)
      _ -> error(:unavailable)
    end
  rescue
    _ -> error(:unavailable)
  catch
    _, _ -> error(:unavailable)
  end

  def handle(_params, _ctx),
    do: {:error, Errors.forbidden("Profile sync status requires operator read access")}

  defp validate_params(params) do
    id = params["nodeId"]

    if Enum.sort(Map.keys(params)) == Enum.sort(~w(id nodeId mutationId)) and
         is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
         String.trim(id) == id and not is_nil(params["mutationId"]) and
         ProfileSnapshot.valid_mutation?(params["mutationId"]),
       do: :ok,
       else: {:error, :invalid_status_request}
  end

  defp validate_receipt(receipt, request) when is_map(receipt) do
    status = receipt["status"]
    acknowledged = status == "acknowledged"
    digest = if status == "unknown", do: nil, else: request["revisionDigest"]

    if Enum.all?(@fields, &Map.has_key?(receipt, &1)) and
         receipt["profileId"] == request["profileId"] and
         receipt["mutationId"] == request["mutationId"] and
         status in ~w(acknowledged pending unknown) and
         receipt["acknowledged"] == acknowledged and receipt["revisionDigest"] == digest,
       do: :ok,
       else: {:error, :invalid_status_receipt}
  end

  defp validate_receipt(_, _), do: {:error, :invalid_status_receipt}

  defp error({:forbidden, _} = reason), do: {:error, reason}
  defp error(:not_found), do: {:error, Errors.error(:not_found, "Profile not found")}

  defp error(reason) when reason in [:invalid_id, :invalid_status_request],
    do: {:error, Errors.invalid_request("Profile sync status request is invalid")}

  defp error(_), do: {:error, Errors.unavailable("Profile sync status is unavailable")}
end
