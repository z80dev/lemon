defmodule LemonMCP.Client.StdioHandler do
  @moduledoc false

  alias LemonMCP.Protocol

  # Invoked by the shared RPC client in the owning MCP client's Task.Supervisor.
  # Notification callbacks never execute inside either client's mailbox.
  # Lemon answers no server-to-client request: every one, `sampling/createMessage`
  # included, receives a method-not-found error.
  def handle(%{"method" => method} = message, reply, _owner, handlers)
      when is_binary(method) do
    case Map.fetch(message, "id") do
      {:ok, id} ->
        reply.(
          Protocol.create_error_response(
            id,
            Protocol.error_code(:method_not_found),
            "Method not found"
          )
        )

      :error ->
        notify(method, Map.get(message, "params", %{}), handlers.notification_handler)
    end
  end

  def handle(message, _reply, owner, _handlers) do
    send(owner, {:rpc_message, message})
  end

  defp notify(method, params, handler) when is_map(params) and is_function(handler, 1) do
    handler.(%{method: method, params: params})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp notify(_method, _params, _handler), do: :ok
end
