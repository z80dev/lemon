defmodule CodingAgent.JoinAwait do
  @moduledoc false

  alias CodingAgent.{ParentQuestions, RunGraph}
  alias LemonAgent.AbortSignal

  @poll_ms 100

  @spec await([String.t()], [String.t()], :wait_all | :wait_any, reference() | nil) ::
          {:ok, map()} | {:parent_question, map()} | {:error, term()}
  def await(run_ids, task_ids, mode, signal) do
    with :ok <- ensure_known_runs(run_ids) do
      do_await(run_ids, task_ids, mode, signal)
    end
  end

  defp do_await(run_ids, task_ids, mode, signal) do
    cond do
      AbortSignal.aborted?(signal) ->
        {:error, :aborted}

      true ->
        case ParentQuestions.waiting_for_task_ids(task_ids) do
          {:ok, request} ->
            {:parent_question, request}

          {:error, :not_found} ->
            case RunGraph.await(run_ids, mode, @poll_ms) do
              {:ok, result} -> {:ok, result}
              {:error, :timeout, _snapshot} -> do_await(run_ids, task_ids, mode, signal)
            end
        end
    end
  end

  defp ensure_known_runs(run_ids) do
    case Enum.find(run_ids, &match?({:error, :not_found}, RunGraph.get(&1))) do
      nil -> :ok
      run_id -> {:error, {:unknown_run, run_id}}
    end
  end
end
