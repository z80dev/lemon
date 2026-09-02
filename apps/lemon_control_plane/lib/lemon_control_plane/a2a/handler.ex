defmodule LemonControlPlane.A2A.Handler do
  @moduledoc false

  alias LemonControlPlane.A2A.{Config, Runner, TaskView}
  alias LemonCore.{A2AStore, Id, RouterBridge}
  alias LemonCore.A2A.Protocol

  @aliases %{
    "message/send" => "SendMessage",
    "message/stream" => "SendStreamingMessage",
    "tasks/get" => "GetTask",
    "tasks/list" => "ListTasks",
    "tasks/cancel" => "CancelTask",
    "tasks/subscribe" => "SubscribeToTask"
  }

  @spec handle(binary(), map(), binary()) ::
          {:ok, map()} | {:stream, binary()} | {:error, integer(), binary()}
  def handle(method, params, peer_id) do
    method = Map.get(@aliases, method, method)

    case method do
      "SendMessage" -> send_message(params, peer_id, false)
      "SendStreamingMessage" -> send_message(params, peer_id, true)
      "GetTask" -> get_task(params, peer_id)
      "ListTasks" -> list_tasks(params, peer_id)
      "CancelTask" -> cancel_task(params, peer_id)
      "SubscribeToTask" -> subscribe(params, peer_id)
      _ -> {:error, -32_601, "Method not found"}
    end
  end

  defp send_message(%{"message" => message}, peer_id, streaming) when is_map(message) do
    context_id = message["contextId"] || Id.uuid7()
    message_id = message["messageId"] || Id.uuid7()

    with {:ok, text} <- Protocol.text(message),
         {:ok, task} <- Runner.start(peer_id, context_id, text, message_id) do
      if streaming do
        {:stream, task.id}
      else
        case Runner.wait(task.id, Config.current().reply_timeout_ms) do
          {:ok, final} -> {:ok, %{"task" => TaskView.render(final)}}
          {:error, :timeout} -> {:ok, %{"task" => TaskView.render(A2AStore.get_task(task.id))}}
          {:error, _} -> {:error, -32_603, "Internal error"}
        end
      end
    else
      {:error, :unsupported_message} -> {:error, -32_602, "Only text message parts are supported"}
      {:error, :turn_limit} -> {:error, -32_000, "Context turn limit reached"}
      {:error, _} -> {:error, -32_603, "Internal error"}
    end
  end

  defp send_message(_, _, _), do: {:error, -32_602, "message is required"}

  defp get_task(params, peer_id) do
    with {:ok, task} <- owned_task(params["id"], peer_id) do
      {:ok, TaskView.render(task)}
    end
  end

  defp list_tasks(params, peer_id) do
    limit = normalize_limit(params["pageSize"] || params["limit"])
    tasks = A2AStore.list_tasks(peer_id, limit: limit) |> Enum.map(&TaskView.render/1)
    {:ok, %{"tasks" => tasks, "nextPageToken" => nil}}
  end

  defp cancel_task(params, peer_id) do
    with {:ok, task} <- owned_task(params["id"], peer_id) do
      if Protocol.terminal_state?(task.state) do
        {:ok, TaskView.render(task)}
      else
        case RouterBridge.abort_run(task.run_id, :a2a_peer_canceled) do
          :ok ->
            {:ok, canceled} =
              A2AStore.update_task(task.id, &Map.put(&1, :state, "TASK_STATE_CANCELED"))

            LemonCore.Bus.broadcast(
              "a2a:task:#{task.id}",
              {:a2a_task_terminal, task.id}
            )

            {:ok, TaskView.render(canceled)}

          {:error, reason} ->
            {:error, -32_603, "cancel failed: the run router is unavailable (#{inspect(reason)})"}
        end
      end
    end
  end

  defp subscribe(params, peer_id) do
    with {:ok, task} <- owned_task(params["id"], peer_id) do
      {:stream, task.id}
    end
  end

  defp owned_task(id, peer_id) when is_binary(id) do
    case A2AStore.get_task(id) do
      %{peer_id: ^peer_id} = task -> {:ok, task}
      _ -> {:error, -32_001, "Task not found"}
    end
  end

  defp owned_task(_, _), do: {:error, -32_602, "task id is required"}

  defp normalize_limit(value) when is_integer(value), do: value |> min(100) |> max(1)
  defp normalize_limit(_), do: 50
end
