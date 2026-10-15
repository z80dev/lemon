defmodule CodingAgent.JoinAwait do
  @moduledoc false

  alias CodingAgent.{ParentQuestions, RunGraph, TaskStore}
  alias LemonAgent.AbortSignal

  @poll_ms 100

  @spec await([String.t()], [String.t()], :wait_all | :wait_any, reference() | nil, keyword()) ::
          {:ok, map()}
          | {:parent_question, map()}
          | {:yield, :timeout | :interrupted}
          | {:error, term()}
  def await(run_ids, task_ids, mode, signal, opts \\ []) do
    deadline =
      case Keyword.get(opts, :timeout_ms) do
        milliseconds when is_integer(milliseconds) ->
          System.monotonic_time(:millisecond) + milliseconds

        _ ->
          :infinity
      end

    interrupted? = Keyword.get(opts, :interrupted?, fn -> false end)

    with :ok <- ensure_known_runs(run_ids) do
      do_await(run_ids, task_ids, mode, signal, deadline, interrupted?)
    end
  end

  defp do_await(run_ids, task_ids, mode, signal, deadline, interrupted?) do
    cond do
      AbortSignal.aborted?(signal) ->
        {:error, :aborted}

      interrupted?.() ->
        {:yield, :interrupted}

      deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
        {:yield, :timeout}

      true ->
        case ParentQuestions.waiting_for_task_ids(task_ids) do
          {:ok, request} ->
            {:parent_question, request}

          {:error, :not_found} ->
            case await_runs(run_ids, task_ids, mode) do
              {:ok, result} ->
                {:ok, result}

              {:error, :timeout, _snapshot} ->
                do_await(run_ids, task_ids, mode, signal, deadline, interrupted?)
            end
        end
    end
  end

  # The run graph retains the original invocation's immutable terminal result.
  # A messaged child has subsequent turns under that same session/run identity;
  # their authoritative status and result live in TaskStore.
  defp await_runs(run_ids, task_ids, mode) do
    turns =
      Enum.reduce(task_ids, %{}, fn task_id, acc ->
        case TaskStore.get_record(task_id) do
          {:ok, %{agent_turn: turn} = record} when turn > 0 ->
            Map.put(acc, record.run_id, record)

          _ ->
            acc
        end
      end)

    if map_size(turns) == 0 do
      RunGraph.await(run_ids, mode, @poll_ms)
    else
      runs =
        Enum.map(run_ids, fn id ->
          {:ok, run} = RunGraph.get(id)

          case turns[id] do
            nil -> run
            record -> Map.merge(run, Map.take(record, [:status, :result, :error]))
          end
        end)

      terminal? = fn run ->
        RunGraph.normalize_status(run[:status]) in [
          :completed,
          :error,
          :lost,
          :killed,
          :cancelled
        ]
      end

      case {mode, Enum.all?(runs, terminal?), Enum.find(runs, terminal?)} do
        {:wait_all, true, _} ->
          {:ok, %{mode: mode, runs: runs}}

        {:wait_any, _, run} when not is_nil(run) ->
          {:ok, %{mode: mode, run: run}}

        _ ->
          Process.sleep(@poll_ms)
          {:error, :timeout, %{mode: mode, runs: runs}}
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
