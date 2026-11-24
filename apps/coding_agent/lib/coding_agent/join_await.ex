defmodule CodingAgent.JoinAwait do
  @moduledoc """
  Message-driven task joins. Subscribe before reading authoritative state, then
  wait on run/task/question changes, child owner and worker monitors or
  cancellation. A single absolute deadline bounds the whole join;
  notifications never extend it.
  """

  alias CodingAgent.{ParentQuestions, RunGraph, TaskRuntime, TaskStore}
  alias LemonAgent.AbortSignal
  alias LemonCore.Bus

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

    topics =
      Enum.flat_map(run_ids, &["run_graph:#{&1}", Bus.run_topic(&1)]) ++
        Enum.map(task_ids, &"task_state:#{&1}") ++
        List.wrap(Keyword.get(opts, :interruption_topic))

    Enum.each(Enum.uniq(topics), &Bus.subscribe/1)

    AbortSignal.subscribe(signal)

    try do
      with :ok <- ensure_known_runs(run_ids) do
        do_await(run_ids, task_ids, mode, signal, deadline, interrupted?)
      end
    after
      AbortSignal.unsubscribe(signal)
      Enum.each(Enum.uniq(topics), &Bus.unsubscribe/1)
    end
  end

  defp do_await(run_ids, task_ids, mode, signal, deadline, interrupted?) do
    owners = [CodingAgent.TaskStoreServer, CodingAgent.RunGraphServer]
    owner_pids = owners |> Enum.map(&Process.whereis/1) |> Enum.filter(&is_pid/1)
    # A child's owner or worker exiting is a change to re-read, not a failure.
    children = TaskRuntime.pids(task_ids)
    monitors = Map.new(Enum.uniq(owner_pids ++ children), &{Process.monitor(&1), &1})

    outcome =
      try do
        cond do
          AbortSignal.aborted?(signal) ->
            {:error, :aborted}

          interrupted?.() ->
            {:yield, :interrupted}

          deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
            {:yield, :timeout}

          true ->
            with :ok <- ensure_known_runs(run_ids) do
              case ParentQuestions.waiting_for_task_ids(task_ids) do
                {:ok, request} ->
                  {:parent_question, request}

                {:error, :not_found} ->
                  case await_runs(run_ids, task_ids, mode) do
                    {:ok, result} -> {:ok, result}
                    :pending -> wait_for_change(signal, deadline, monitors, owner_pids)
                  end
              end
            end
        end
      after
        Enum.each(monitors, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
      end

    case outcome do
      :changed -> do_await(run_ids, task_ids, mode, signal, deadline, interrupted?)
      result -> result
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

          {:ok, %{status: :interrupted} = record} ->
            Map.put(acc, record.run_id, record)

          _ ->
            acc
        end
      end)

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
        :interrupted,
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
        :pending
    end
  end

  defp wait_for_change(signal, deadline, monitors, owner_pids) do
    timeout =
      if deadline == :infinity,
        do: :infinity,
        else: max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:lemon_abort, ^signal, _kind} ->
        {:error, :aborted}

      {:run_graph, :state_changed, _id} ->
        :changed

      {:task_state, :changed, _id} ->
        :changed

      %LemonCore.Event{type: type}
      when type in [
             :parent_question_requested,
             :parent_question_answered,
             :parent_question_cancelled,
             :parent_question_timed_out,
             :parent_question_error
           ] ->
        :changed

      {:parent_question, :delivered, _id} ->
        :changed

      {:session_coord, :steering_changed} ->
        :changed

      {:DOWN, ref, :process, pid, _reason} when is_map_key(monitors, ref) ->
        if pid in owner_pids, do: {:error, :coordination_owner_down}, else: :changed
    after
      timeout -> {:yield, :timeout}
    end
  end

  defp ensure_known_runs(run_ids) do
    case Enum.find(run_ids, &match?({:error, :not_found}, RunGraph.get(&1))) do
      nil -> :ok
      run_id -> {:error, {:unknown_run, run_id}}
    end
  end
end
