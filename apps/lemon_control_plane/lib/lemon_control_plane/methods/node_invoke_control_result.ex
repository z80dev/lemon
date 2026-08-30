defmodule LemonControlPlane.Methods.NodeInvokeControlResult do
  @moduledoc """
  Accepts an authenticated destination acknowledgement for a live invocation control.

  Control ownership is held by `LemonCore.NodeRegistry`. A result is accepted
  only from the same node connection and credential generation that received
  the original invocation and only while that invocation remains active.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Protocol.Errors

  @rejection_reasons ~w(
    terminal
    run_mismatch
    unsupported_operation
    invalid_text
    text_too_large
    unsupported
    rejected
    executor_error
    executor_unavailable
  )

  @impl true
  def name, do: "node.invoke.control.result"

  @impl true
  def scopes, do: [:invoke]

  @impl true
  def handle(params, ctx) do
    auth = ctx[:auth] || ctx
    role = get_field(auth, :role)
    node_id = get_field(auth, :client_id)
    connection_pid = ctx[:conn_pid]
    generation = session_generation(auth)
    control_id = params["controlId"]
    invoke_id = params["invokeId"]
    run_id = params["runId"]
    accepted = params["accepted"]
    reason = params["reason"]

    cond do
      role != :node ->
        {:error, Errors.forbidden("This method requires node role")}

      not is_binary(node_id) or node_id == "" ->
        {:error, Errors.forbidden("Authenticated node identity is required")}

      not is_pid(connection_pid) ->
        {:error, Errors.forbidden("Authenticated node connection is required")}

      not nonempty_string?(control_id) ->
        {:error, Errors.invalid_request("controlId must be a non-empty string")}

      not nonempty_string?(invoke_id) ->
        {:error, Errors.invalid_request("invokeId must be a non-empty string")}

      not nonempty_string?(run_id) ->
        {:error, Errors.invalid_request("runId must be a non-empty string")}

      not is_boolean(accepted) ->
        {:error, Errors.invalid_request("accepted must be a boolean")}

      accepted and not is_nil(reason) ->
        {:error, Errors.invalid_request("accepted controls cannot include a reason")}

      not accepted and reason not in @rejection_reasons ->
        {:error, Errors.invalid_request("reason is not an allowed rejection code")}

      not current_session?(node_id, generation) ->
        {:error, Errors.forbidden("Node session has been superseded")}

      true ->
        complete(
          node_id,
          connection_pid,
          generation,
          control_id,
          invoke_id,
          run_id,
          accepted,
          reason
        )
    end
  end

  defp complete(
         node_id,
         connection_pid,
         generation,
         control_id,
         invoke_id,
         run_id,
         accepted,
         reason
       ) do
    case LemonCore.NodeRegistry.complete_control_session(
           node_id,
           connection_pid,
           generation,
           control_id,
           invoke_id,
           run_id,
           accepted,
           reason
         ) do
      :ok ->
        {:ok,
         %{
           "controlId" => control_id,
           "invokeId" => invoke_id,
           "runId" => run_id,
           "received" => true,
           "accepted" => accepted,
           "cleanup" => %{
             "includesText" => false,
             "includesCredentials" => false,
             "includesSecretValues" => false
           }
         }}

      {:error, :wrong_node} ->
        {:error, Errors.forbidden("Control belongs to a different node")}

      {:error, reason} when reason in [:wrong_invocation, :wrong_run] ->
        {:error, Errors.forbidden("Control identity does not match its invocation")}

      {:error, :stale_session} ->
        {:error, Errors.forbidden("Control belongs to a superseded node session")}

      {:error, reason} when reason in [:not_found, :terminal] ->
        {:error, Errors.conflict("Invocation control is no longer pending")}
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

  defp current_session?(node_id, generation) when is_integer(generation) do
    case TokenStore.current_node_generation(node_id) do
      nil -> generation == 0
      current -> current == generation
    end
  end

  defp current_session?(_node_id, _generation), do: false

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
