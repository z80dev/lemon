defmodule LemonControlPlane.Methods.NodeInvokeEvent do
  @moduledoc """
  Forwards live coding-agent events from the authenticated invocation session.

  NodeRegistry owns recipient delivery, session binding, sequencing and bounded
  JSON validation. This method does not persist events or replay terminal work.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.NodeRegistry

  @impl true
  def name, do: "node.invoke.event"

  @impl true
  def scopes, do: [:invoke, :event]

  @impl true
  def handle(params, ctx) do
    auth = ctx[:auth] || ctx
    role = get_field(auth, :role)
    node_id = get_field(auth, :client_id)
    connection_pid = ctx[:conn_pid]
    generation = session_generation(auth)
    invoke_id = params["invokeId"]
    seq = params["seq"]
    event = params["event"]

    cond do
      role != :node ->
        {:error, Errors.forbidden("This method requires node role")}

      not is_binary(node_id) or node_id == "" ->
        {:error, Errors.forbidden("Authenticated node identity is required")}

      not is_pid(connection_pid) ->
        {:error, Errors.forbidden("Authenticated node connection is required")}

      not current_session?(node_id, generation) ->
        {:error, Errors.forbidden("Node session has been superseded")}

      not is_binary(invoke_id) or String.trim(invoke_id) == "" ->
        {:error, Errors.invalid_request("invokeId must be a non-empty string")}

      not is_integer(seq) or seq <= 0 ->
        {:error, Errors.invalid_request("seq must be a positive integer")}

      not is_map(event) ->
        {:error, Errors.invalid_request("event must be an object")}

      true ->
        accept_event(node_id, connection_pid, generation, invoke_id, seq, event)
    end
  end

  defp accept_event(node_id, connection_pid, generation, invoke_id, seq, event) do
    case NodeRegistry.event_session(node_id, connection_pid, generation, invoke_id, seq, event) do
      {:ok, status} ->
        {:ok,
         %{
           "invokeId" => invoke_id,
           "seq" => seq,
           "received" => true,
           "duplicate" => status == :duplicate
         }}

      {:error, :wrong_node} ->
        {:error, Errors.forbidden("Invocation belongs to a different node")}

      {:error, :stale_session} ->
        {:error, Errors.forbidden("Invocation belongs to a superseded node session")}

      {:error, :terminal} ->
        {:error, Errors.conflict("Invocation is no longer pending")}

      {:error, :unsupported} ->
        {:error, Errors.invalid_request("Only coding_agent.run invocations may stream events")}

      {:error, :sequence_gap} ->
        {:error, Errors.conflict("Event sequence must immediately follow the latest accepted event")}

      {:error, :invalid_seq} ->
        {:error, Errors.invalid_request("seq must be a positive integer")}

      {:error, :invalid_event_type} ->
        {:error, Errors.invalid_request("event type is not allowed")}

      {:error, {:invalid_payload, kind}} ->
        {:error, Errors.error(:invalid_request, "event violates JSON payload policy", kind)}
    end
  end

  defp session_generation(auth) do
    auth
    |> get_field(:identity)
    |> case do
      identity when is_map(identity) -> get_field(identity, :sessionGeneration) || 0
      _ -> 0
    end
  end

  defp current_session?(node_id, generation) when is_integer(generation) and generation >= 0 do
    case TokenStore.current_node_generation(node_id) do
      nil -> generation == 0
      current -> current == generation
    end
  end

  defp current_session?(_node_id, _generation), do: false

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
