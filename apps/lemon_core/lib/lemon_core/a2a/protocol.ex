defmodule LemonCore.A2A.Protocol do
  @moduledoc """
  Small, dependency-free helpers for the A2A v1.0 JSON-RPC wire format.

  The helpers intentionally preserve unknown fields. Lemon can therefore talk
  to newer peers without treating optional protocol additions as errors.
  """

  @terminal_states ~w(TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_REJECTED)

  @spec terminal_state?(term()) :: boolean()
  def terminal_state?(state), do: state in @terminal_states

  @spec request(binary(), map(), term()) :: map()
  def request(method, params, id \\ LemonCore.Id.uuid()) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  @spec response(term(), map()) :: map()
  def response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @spec error(term(), integer(), binary(), term()) :: map()
  def error(id, code, message, data \\ nil) do
    detail = %{"code" => code, "message" => message}
    detail = if is_nil(data), do: detail, else: Map.put(detail, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => detail}
  end

  @spec message(binary(), binary(), keyword()) :: map()
  def message(role, text, opts \\ []) do
    %{
      "messageId" => Keyword.get(opts, :message_id, LemonCore.Id.uuid7()),
      "role" => role,
      "parts" => [%{"text" => text, "mediaType" => "text/plain"}]
    }
    |> maybe_put("contextId", Keyword.get(opts, :context_id))
    |> maybe_put("taskId", Keyword.get(opts, :task_id))
  end

  @spec text(map()) :: {:ok, binary()} | {:error, :unsupported_message}
  def text(%{"parts" => parts}) when is_list(parts) do
    value =
      parts
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")
      |> String.trim()

    if value == "", do: {:error, :unsupported_message}, else: {:ok, value}
  end

  def text(_), do: {:error, :unsupported_message}

  @spec task(binary(), binary(), binary(), map(), keyword()) :: map()
  def task(id, context_id, state, message, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    %{
      "id" => id,
      "contextId" => context_id,
      "status" => %{"state" => state, "timestamp" => timestamp, "message" => message},
      "history" => Keyword.get(opts, :history, [])
    }
    |> maybe_put("artifacts", Keyword.get(opts, :artifacts))
  end

  @spec unwrap_task(map()) :: {:ok, map()} | {:error, term()}
  def unwrap_task(%{"result" => %{"task" => task}}) when is_map(task), do: {:ok, task}
  def unwrap_task(%{"result" => %{"message" => message}}) when is_map(message), do: {:ok, message}
  def unwrap_task(%{"result" => task}) when is_map(task), do: {:ok, task}
  def unwrap_task(%{"error" => error}), do: {:error, {:remote_error, error}}
  def unwrap_task(other), do: {:error, {:invalid_response, other}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
