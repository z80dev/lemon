defmodule LemonControlPlane.Methods.NodeInvokeActive do
  @moduledoc """
  Handler for `node.invoke.active`.

  After connecting, and after its cancellation barrier, a node's worker reports
  every invocation it still runs or is still stopping. Unresolved session
  presence left by the node's earlier connections for any other invocation is
  then cleared: that execution is proven stopped. Only the node's current
  authenticated session can report.
  """

  @behaviour LemonControlPlane.Method

  import LemonControlPlane.Methods.NodeSession,
    only: [session_generation: 1, current_session?: 2, get_field: 2]

  alias LemonControlPlane.Protocol.Errors

  @max_invoke_ids 1_024

  @impl true
  def name, do: "node.invoke.active"

  @impl true
  def scopes, do: [:invoke]

  @impl true
  def handle(params, ctx) do
    auth = ctx[:auth] || ctx
    node_id = get_field(auth, :client_id)
    connection_pid = ctx[:conn_pid]
    generation = session_generation(auth)
    invoke_ids = params["invokeIds"]

    cond do
      get_field(auth, :role) != :node ->
        {:error, Errors.forbidden("This method requires node role")}

      not is_binary(node_id) or node_id == "" ->
        {:error, Errors.forbidden("Authenticated node identity is required")}

      not is_list(invoke_ids) or length(invoke_ids) > @max_invoke_ids or
          not Enum.all?(invoke_ids, &(is_binary(&1) and &1 != "")) ->
        {:error, Errors.invalid_request("invokeIds must be a list of invocation ids")}

      not is_pid(connection_pid) ->
        {:error, Errors.forbidden("Authenticated node connection is required")}

      not current_session?(node_id, generation) ->
        {:error, Errors.forbidden("Node session has been superseded")}

      true ->
        case LemonAgent.NodeRegistry.report_active(
               node_id,
               connection_pid,
               generation,
               invoke_ids
             ) do
          :ok ->
            {:ok, %{"received" => true}}

          {:error, :stale_session} ->
            {:error, Errors.forbidden("Node session has been superseded")}

          {:error, :unavailable} ->
            {:error, Errors.unavailable("Session activity is unavailable")}
        end
    end
  end
end
