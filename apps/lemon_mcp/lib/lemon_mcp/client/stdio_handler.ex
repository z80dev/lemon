defmodule LemonMCP.Client.StdioHandler do
  @moduledoc false

  alias LemonMCP.Protocol

  # Invoked by the shared RPC client in the owning MCP client's Task.Supervisor.
  # Policy callbacks never execute inside either client's mailbox.
  def handle(%{"method" => method} = message, reply, _owner, handlers)
      when is_binary(method) do
    case Map.fetch(message, "id") do
      {:ok, id} -> reply.(request_response(id, method, Map.get(message, "params", %{}), handlers))
      :error -> notify(method, Map.get(message, "params", %{}), handlers.notification_handler)
    end
  end

  def handle(message, _reply, owner, _handlers) do
    send(owner, {:rpc_message, message})
  end

  defp request_response(id, "sampling/createMessage", params, handlers) do
    cond do
      not is_map(params) and not is_nil(params) ->
        Protocol.create_error_response(
          id,
          Protocol.error_code(:invalid_params),
          "Invalid sampling params"
        )

      is_function(handlers.sampling_handler, 1) ->
        sample(id, params || %{}, handlers.sampling_handler)

      true ->
        Protocol.create_error_response(id, -1, "Sampling is not enabled")
    end
  end

  defp request_response(id, _method, _params, _handlers) do
    Protocol.create_error_response(id, Protocol.error_code(:method_not_found), "Method not found")
  end

  defp sample(id, params, handler) do
    case handler.(params) do
      {:ok, result} when is_map(result) ->
        Protocol.create_response(id, result)

      {:error, reason} ->
        Protocol.create_error_response(id, -1, "Sampling request rejected", inspect(reason))

      other ->
        Protocol.create_error_response(
          id,
          Protocol.error_code(:internal_error),
          "Invalid sampling handler response",
          inspect(other)
        )
    end
  rescue
    _ -> sampling_failure(id)
  catch
    _, _ -> sampling_failure(id)
  end

  defp sampling_failure(id) do
    Protocol.create_error_response(
      id,
      Protocol.error_code(:internal_error),
      "Sampling handler failed"
    )
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
