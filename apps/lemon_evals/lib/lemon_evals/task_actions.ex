defmodule LemonEvals.TaskActions do
  @moduledoc """
  Opt-in content-free task-action recorder and offline JSONL usage report.

  Start in the runtime that executes task tools, then flush after the eval or
  arena run settles. The telemetry callback only enqueues an allowlisted record;
  the recorder owns file I/O. Stop it to detach. `report/1` requires no runtime.
  """
  use GenServer, restart: :temporary

  @event [:coding_agent, :task, :action]
  @json_event Enum.map(@event, &Atom.to_string/1)
  @fields [:action, :kind, :outcome, :model, :depth, :run_id]
  @dispatch ~w(run swarm poll join wait get message steer cancel unknown)

  def start_link(path), do: GenServer.start_link(__MODULE__, path)
  def flush(pid), do: GenServer.call(pid, :flush)

  @doc false
  def handle_event(@event, measurements, metadata, pid) do
    record = %{
      event: @event,
      measurements: Map.take(measurements, [:count]),
      metadata: Map.take(metadata, @fields)
    }

    GenServer.cast(pid, {:record, record})
  end

  @impl true
  def init(path) do
    # Supervisor shutdown must run terminate/2 to detach the global handler.
    Process.flag(:trap_exit, true)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        File.chmod!(path, 0o600)
        handler = {__MODULE__, self()}
        :ok = :telemetry.attach(handler, @event, &__MODULE__.handle_event/4, self())
        {:ok, %{file: file, handler: handler}}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:record, record}, state) do
    case :file.write(state.file, [Jason.encode!(record), "\n"]) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:write_failed, reason}, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :file.sync(state.file), state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler)
    File.close(state.file)
  end

  @doc "Aggregates recorded observations, preserving missing model/depth/run identity as null."
  def report(path) do
    counts =
      path
      |> File.stream!()
      |> Stream.with_index(1)
      |> Enum.reduce(%{}, fn {line, number}, counts ->
        case decode(line, number) do
          nil -> counts
          key -> Map.update(counts, key, 1, &(&1 + 1))
        end
      end)

    rows =
      counts
      |> Enum.map(fn {{run_id, action, kind, outcome, model, depth}, count} ->
        %{
          run_id: run_id,
          action: action,
          kind: kind,
          outcome: outcome,
          model: model,
          depth: depth,
          count: count
        }
      end)
      |> Enum.sort()

    %{
      schema_version: 1,
      event_count: total(rows),
      total_dispatches: rows |> Enum.filter(&(&1.kind == "dispatch")) |> total(),
      per_action: action_counts(rows),
      per_run:
        rows
        |> Enum.group_by(& &1.run_id)
        |> Enum.map(fn {run_id, run_rows} ->
          %{run_id: run_id, event_count: total(run_rows), per_action: action_counts(run_rows)}
        end)
        |> Enum.sort(),
      breakdown: rows
    }
  end

  defp decode(line, number) do
    case Jason.decode(line) do
      {:ok, %{"event" => @json_event} = record} -> decode_action(record, number)
      {:ok, %{"event" => _}} -> nil
      _ -> invalid!(number)
    end
  end

  defp decode_action(
         %{
           "measurements" => %{"count" => 1},
           "metadata" => %{
             "action" => action,
             "kind" => kind,
             "outcome" => outcome,
             "model" => model,
             "depth" => depth,
             "run_id" => run_id
           }
         },
         number
       ) do
    valid_action =
      (kind == "dispatch" and action in @dispatch) or
        (kind == "feature" and action in ["batch", "steps"]) or
        (kind == "launch" and action == "speculative_launch")

    if valid_action and outcome in ~w(ok error aborted exception) and
         (is_nil(model) or is_binary(model)) and
         (is_nil(run_id) or is_binary(run_id)) and
         (is_nil(depth) or (is_integer(depth) and depth >= 0)) do
      {run_id, action, kind, outcome, model, depth}
    else
      invalid!(number)
    end
  end

  defp decode_action(_record, number), do: invalid!(number)

  defp invalid!(number),
    do: raise(ArgumentError, "Invalid task action telemetry at line #{number}")

  defp action_counts(rows) do
    rows
    |> Enum.group_by(&{&1.action, &1.kind})
    |> Enum.map(fn {{action, kind}, grouped} ->
      %{action: action, kind: kind, count: total(grouped)}
    end)
    |> Enum.sort()
  end

  defp total(rows), do: Enum.reduce(rows, 0, &(&1.count + &2))
end
