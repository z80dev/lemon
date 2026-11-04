defmodule LemonCore.AgentMessaging do
  @moduledoc """
  Optional runtime seam for named-agent discovery and correlated messaging.

  A routing runtime registers its complete implementation with `configure/1`;
  core has no compile-time dependency on that application. The implementation
  owns native eligibility, authorization, transport bindings and receipts.
  Identities themselves remain durable in `LemonCore.AgentIdentity`.

  No configured runtime returns `{:error, :unavailable}`, including for rename.
  Query failures never become an empty roster or an idle status. An exception,
  exit, throw or malformed mutation acknowledgement is `:outcome_unknown`:
  callers must retain the original message ID and reconcile, not replay it.
  """

  @runtime_key :agent_messaging_runtime

  @callback list(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback rename(binary(), binary(), binary() | nil) :: {:ok, map()} | {:error, term()}
  @callback send(binary(), binary(), binary(), binary(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback get(binary(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  @callback register_external(binary(), map(), pid()) :: {:ok, map()} | {:error, term()}
  @callback unregister_external(binary(), binary(), pid()) :: :ok | {:error, term()}
  @callback complete_external(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}

  @doc "Register a complete messaging runtime, or unregister it with `nil`."
  @spec configure(module() | nil) :: :ok | {:error, term()}
  def configure(nil) do
    Application.delete_env(:lemon_core, @runtime_key)
    :ok
  end

  def configure(module) do
    with :ok <- LemonCore.Contract.validate(module, __MODULE__) do
      Application.put_env(:lemon_core, @runtime_key, module)
      :ok
    end
  end

  @doc "Discover eligible identities with runtime status, within one authorized scope."
  def list(scope, opts \\ []), do: call(:list, [scope, opts], :query, :list)

  @doc "Rename an eligible existing identity without changing its stable ID."
  def rename(scope, id, name), do: call(:rename, [scope, id, name], :mutation, :map)

  @doc "Send with the required fixed `:message_id`; acceptance is not a completed answer."
  def send(scope, source_id, target, text, opts \\ []),
    do: call(:send, [scope, source_id, target, text, opts], :mutation, :map)

  @doc "Read a receipt scoped to its exact sender."
  def get(scope, source_id, message_id),
    do: call(:get, [scope, source_id, message_id], :query, :map)

  @doc "Bind a durable external identity to its authenticated connection."
  def register_external(scope, attrs, conn_pid),
    do: call(:register_external, [scope, attrs, conn_pid], :mutation, :map)

  @doc "Delete an external identity only through its owning connection."
  def unregister_external(scope, id, conn_pid),
    do: call(:unregister_external, [scope, id, conn_pid], :mutation, :ok)

  @doc "Accept a bounded completion only from the exact target transport."
  def complete_external(conn_pid, message_id, completion),
    do: call(:complete_external, [conn_pid, message_id, completion], :mutation, :map)

  defp call(function, args, operation, shape) do
    case Application.get_env(:lemon_core, @runtime_key) do
      nil -> {:error, :unavailable}
      module -> invoke(module, function, args, operation, shape)
    end
  end

  defp invoke(module, function, args, operation, shape) do
    module
    |> apply(function, args)
    |> acknowledgement(shape, operation)
  rescue
    _ -> failure(operation, :query_failed)
  catch
    _, _ -> failure(operation, :unavailable)
  end

  defp acknowledgement({:error, _} = error, _shape, _operation), do: error
  defp acknowledgement(:ok, :ok, _operation), do: :ok
  defp acknowledgement({:ok, value}, :map, _operation) when is_map(value), do: {:ok, value}

  defp acknowledgement({:ok, entries}, :list, operation) when is_list(entries) do
    if Enum.all?(entries, &is_map/1), do: {:ok, entries}, else: failure(operation, :query_failed)
  end

  defp acknowledgement(_result, _shape, operation), do: failure(operation, :query_failed)

  defp failure(:mutation, _reason), do: {:error, :outcome_unknown}
  defp failure(:query, reason), do: {:error, reason}
end
