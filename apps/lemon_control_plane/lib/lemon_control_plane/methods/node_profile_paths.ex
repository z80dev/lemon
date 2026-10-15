defmodule LemonControlPlane.Methods.NodeProfilePaths do
  @moduledoc """
  Reads destination-owned profile workspace/skill paths without provisioning.

  Only trusted operators may query an explicitly identified execution node.
  The controller validates identity and acknowledgement shape, but never guesses
  the destination state root or replaces it with a host's project cwd.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.profile.paths"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, %{auth: %{role: :operator} = auth} = ctx) when is_map(params) do
    with :ok <- Authorize.authorize(auth, name(), scopes()),
         :ok <- validate_params(params),
         {:ok, result} <-
           LemonControlPlane.NodeIO.invoke(
             params["nodeId"],
             name(),
             %{"profileId" => params["profileId"]},
             ctx
           ),
         :ok <- validate_result(result, params["profileId"]) do
      {:ok,
       Map.take(result, ~w(profileId workspacePath skillsPath))
       |> Map.put("nodeId", params["nodeId"])}
    else
      {:error, {:forbidden, _}} = error ->
        error

      {:error, :invalid_request} ->
        {:error, Errors.invalid_request("Invalid profile paths request")}

      _ ->
        {:error, Errors.unavailable("Profile paths are unavailable")}
    end
  rescue
    _ -> {:error, Errors.unavailable("Profile paths are unavailable")}
  catch
    _, _ -> {:error, Errors.unavailable("Profile paths are unavailable")}
  end

  def handle(_params, _ctx),
    do: {:error, Errors.forbidden("Profile paths require operator read access")}

  defp validate_params(params) do
    node = params["nodeId"]

    with true <- Enum.sort(Map.keys(params)) == ~w(nodeId profileId),
         true <-
           is_binary(node) and byte_size(node) in 1..128 and String.valid?(node) and
             String.trim(node) == node and not String.contains?(node, <<0>>),
         {:ok, _controller_paths_not_used} <- LemonCore.ProfileStore.paths(params["profileId"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_result(
         %{"profileId" => id, "workspacePath" => workspace, "skillsPath" => skills},
         id
       )
       when is_binary(workspace) and is_binary(skills) do
    if String.valid?(workspace) and String.valid?(skills) and
         not String.contains?(workspace, <<0>>) and Path.type(workspace) == :absolute and
         Path.expand(workspace) == workspace and
         skills == Path.join([workspace, ".lemon", "skill"]),
       do: :ok,
       else: {:error, :invalid_acknowledgement}
  end

  defp validate_result(_, _), do: {:error, :invalid_acknowledgement}
end
