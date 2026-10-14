defmodule LemonControlPlane.Methods.NodeNativeLineageFloor do
  @moduledoc "Receives an immutable executing-host policy floor before native startup effects."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{NodeRegistry, RunRequest}

  @impl true
  def name, do: "node.native.lineage.floor"

  @impl true
  def scopes, do: [:invoke]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx) do
    with {:ok, source, transport} <- source(params, ctx, false),
         policy when is_map(policy) <- params["toolPolicy"],
         {:ok, _} <- LemonCore.JSONPayload.validate(policy, LemonCore.ToolPolicy.execution_json_opts()),
         {:ok, policy} <- LemonCore.ToolPolicy.normalize(policy) do
      case LemonRouter.RunOrchestrator.register_native_source_floor_from_node(source, policy, transport) do
        :ok -> {:ok, %{}}
        {:error, _} -> {:error, Errors.forbidden("Native source floor receipt is unavailable")}
      end
    else
      {:error, {_kind, _message} = error} -> {:error, error}
      _ -> {:error, Errors.invalid_request("Invalid native source floor receipt")}
    end
  end

  @doc false
  def source(params, ctx, require_handle \\ true) do
    auth = ctx[:auth] || %{}
    node_id = get_field(auth, :client_id)
    pid = ctx[:conn_pid]
    identity = get_field(auth, :identity) || %{}
    generation = get_field(identity, :sessionGeneration) || 0
    run_id = params["sourceRunId"]
    handle = params["lineageHandle"]

    with :node <- get_field(auth, :role),
         true <- is_binary(node_id) and node_id != "" and is_pid(pid),
         true <- is_integer(generation) and generation >= 0,
         true <- current_generation?(node_id, generation),
         {:ok, %{id: ^node_id, pid: ^pid, generation: ^generation}} <- NodeRegistry.resolve_id(node_id),
         :ok <- RunRequest.validate_invocation_context_key(run_id),
         true <- run_id != "",
         true <- valid_handle?(params, handle, require_handle) do
      source = if is_nil(handle), do: %{run_id: run_id}, else: %{run_id: run_id, lineage_handle: handle}
      {:ok, source, %{node_id: node_id, connection_pid: pid, generation: generation}}
    else
      _ -> {:error, Errors.forbidden("Authenticated current node source is required")}
    end
  end

  defp valid_handle?(params, nil, false), do: not Map.has_key?(params, "lineageHandle")
  defp valid_handle?(_params, handle, _required), do: is_binary(handle) and byte_size(handle) == 43

  defp current_generation?(node_id, generation) do
    case TokenStore.current_node_generation(node_id) do
      nil -> generation == 0
      current -> current == generation
    end
  end

  defp get_field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
