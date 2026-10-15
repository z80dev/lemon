defmodule CodingAgent.Tools.Task.Wait do
  @moduledoc """
  Waits for the first result from native task children owned by the caller.

  Without explicit task IDs, completed, failed and cancelled children remain
  eligible until a wait returns their result. Only that returned child is marked
  observed through the serialized TaskStore writer. Explicit IDs may revisit an
  observed result. Waiting and followup reservations use the existing task join
  path, including cancellation and yielding to pending parent questions.
  """

  alias CodingAgent.{TaskStore, TaskStoreServer}
  alias CodingAgent.Tools.Task.{Control, Result}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @safety_cap_ms 30 * 60 * 1000

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    %AgentTool{
      name: "wait",
      timeout_ms: :infinity,
      label: "Wait for Child",
      description:
        "Wait for the first owned native task child result, leaving siblings running. " <>
          "Omit task_ids to consume the next unobserved child completion, including children " <>
          "that already finished. Explicit task_ids may revisit results. Failures and " <>
          "cancellations are returned too. Does not wait on shell jobs or background processes.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_ids" => %{
            "type" => "array",
            "minItems" => 1,
            "items" => %{"type" => "string", "minLength" => 1},
            "description" =>
              "Optional owned native child task IDs. Waits for the first result, not all children; excludes shell jobs."
          }
        },
        "required" => []
      },
      execute: fn _tool_call_id, params, signal, _on_update -> execute(params, signal, opts) end
    }
  end

  @spec execute(map(), reference() | nil, keyword()) :: AgentToolResult.t() | {:error, String.t()}
  def execute(params, signal, opts) do
    with {:ok, task_ids} <- select_task_ids(params, opts),
         :ok <- authorize_task_ids(task_ids, opts) do
      timeout_ms = min(Keyword.get(opts, :wait_timeout_ms, @safety_cap_ms), @safety_cap_ms)

      interrupted? = fn ->
        case Keyword.get(opts, :session_pid) do
          session when is_pid(session) ->
            CodingAgent.Session.has_steering_messages?(session, signal)

          _ ->
            false
        end
      end

      case Result.do_join(%{"task_ids" => task_ids, "mode" => "wait_any"}, signal,
             timeout_ms: timeout_ms,
             interrupted?: interrupted?
           ) do
        %AgentToolResult{} = result ->
          observe_winner(result)
          result

        error ->
          error
      end
    end
  end

  defp select_task_ids(params, opts) do
    case Map.fetch(params, "task_ids") do
      {:ok, task_ids} ->
        if is_list(task_ids) and task_ids != [] and
             Enum.all?(task_ids, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.uniq(task_ids)}
        else
          {:error, "task_ids must be a nonempty array of nonempty strings"}
        end

      :error ->
        owner = Control.owner(opts)

        task_ids =
          TaskStore.list()
          |> Enum.filter(fn {_id, record} ->
            native_task?(record) and record[:owner] == owner and
              record[:status] in [:queued, :running, :completed, :error, :cancelled] and
              is_nil(record[:wait_observed_at])
          end)
          |> Enum.map(fn {id, _record} -> id end)

        case task_ids do
          [] -> {:error, "No outstanding or unobserved native child tasks owned by this session"}
          ids -> {:ok, ids}
        end
    end
  end

  defp authorize_task_ids(task_ids, opts) do
    Enum.reduce_while(task_ids, :ok, fn id, :ok ->
      with :ok <- Control.authorize(id, opts),
           {:ok, record} <- TaskStore.get_record(id),
           true <- native_task?(record) do
        {:cont, :ok}
      else
        {:error, message} when is_binary(message) -> {:halt, {:error, message}}
        _ -> {:halt, {:error, "Unknown task_id: #{id}"}}
      end
    end)
  end

  defp native_task?(record) do
    Map.has_key?(record, :owner) and Map.get(record, :kind, :task) == :task
  end

  defp observe_winner(%AgentToolResult{details: %{status: "completed", tasks: tasks}}) do
    Enum.each(tasks, fn
      %{task_id: task_id, status: status}
      when is_binary(task_id) and status in ["completed", "error", "cancelled"] ->
        TaskStoreServer.update_record(task_id, fn record ->
          Map.put_new(record, :wait_observed_at, System.system_time(:millisecond))
        end)

      _ ->
        :ok
    end)
  end

  defp observe_winner(_result), do: :ok
end
