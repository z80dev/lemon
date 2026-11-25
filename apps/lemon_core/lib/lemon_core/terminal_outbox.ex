defmodule LemonCore.TerminalOutbox do
  @moduledoc """
  Bounded replay of committed run completions. Notification and projections
  have independent acknowledgements; no acknowledgement can rewrite a decision.
  Bus publication is at-least-once. Consumers can deduplicate by `meta.event_id`.
  """
  use GenServer

  alias LemonCore.{Bus, Event, Events, Store}

  @table :run_terminal_pending
  @batch_size 8
  @interval_ms 5_000
  @live_grace_ms 30_000
  @max_auto_attempts 8

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Read the immutable, content-free decision, independently of volatile run data."
  def decision(server \\ Store, run_id), do: Store.fetch(server, :run_terminals, run_id)

  @doc "Read the committed replay source while an effect remains unacknowledged."
  def pending(server \\ Store, run_id) do
    with {:ok, %{digest: digest}} <- decision(server, run_id),
         {:ok, row} <- Store.fetch(server, @table, run_id) do
      case row do
        %{digest: ^digest} -> {:ok, row}
        nil -> {:ok, nil}
        _ -> {:error, :invalid_terminal_payload}
      end
    end
  end

  @doc "Read effect status and retry counts without exposing the replay payload."
  def delivery_status(run_id) do
    with {:ok, %{digest: _}} <- decision(run_id),
         {:ok, row} <- pending(run_id) do
      case row do
        nil -> {:ok, %{state: :not_pending}}
        %{} -> {:ok, Map.take(row, [:notification, :projections, :presentation, :failures])}
      end
    end
  end

  @doc "Retry pending router presentation without resubmitting execution."
  def repair_delivery(run_id) do
    with_pending(Store, run_id, fn
      %{record: record, presentation: status} when status != :done ->
        repair_presentation(Store, run_id, record)

      _ ->
        :ok
    end)
  end

  @doc "Repair the session index and finalization hooks from a committed replay source."
  def repair(server \\ Store, run_id) do
    with_pending(server, run_id, &repair_projections(server, run_id, &1))
  end

  defp repair_projections(server, run_id, %{projections: status, record: %{summary: summary}})
       when status != :done do
    case Store.finalize_run(server, run_id, summary) do
      :ok ->
        case pending(server, run_id) do
          {:ok, %{projections: status}} when status != :done -> {:error, :projections_pending}
          {:ok, _} -> :ok
          error -> error
        end

      error ->
        _ = failed(server, run_id, :projections)
        error
    end
  end

  defp repair_projections(_server, _run_id, _row), do: :ok

  @doc false
  def with_history_deletion(server \\ Store, session_key, delete_history) do
    session_lock(server, session_key, fn ->
      with {:ok, removed?} <- remove_session_payloads(server, session_key, nil, false),
           :ok <- if(removed?, do: Store.sync(server), else: :ok) do
        delete_history.()
      end
    end)
  end

  defp remove_session_payloads(server, session_key, cursor, removed?) do
    with {:ok, rows} <- Store.terminal_pending_page(server, cursor, @batch_size) do
      entries =
        for {run_id, %{record: %{summary: %{session_key: ^session_key}}} = row} <- rows,
            do: {@table, run_id, row}

      with :ok <- if(entries == [], do: :ok, else: Store.compare_and_delete_many(server, entries)) do
        removed? = removed? or entries != []

        if length(rows) == @batch_size,
          do: remove_session_payloads(server, session_key, elem(List.last(rows), 0), removed?),
          else: {:ok, removed?}
      end
    end
  end

  defp with_pending(server, run_id, fun) do
    case pending(server, run_id) do
      {:ok, %{record: %{summary: %{session_key: session_key}}}} when is_binary(session_key) ->
        session_lock(server, session_key, fn ->
          with :ok <- replay_admitted(server, session_key),
               {:ok, row} <- pending(server, run_id) do
            fun.(row)
          end
        end)

      {:ok, row} ->
        fun.(row)

      error ->
        error
    end
  end

  defp replay_admitted(Store, session_key),
    do: LemonCore.LifecycleFenceStore.check_admission(session_key)

  defp replay_admitted(_store, _session_key), do: :ok

  defp session_lock(server, session_key, fun) do
    # Only local detached effects need serializing against history deletion.
    # The router lifecycle fence excludes active run owners during deletion.
    case :global.trans({{__MODULE__, server, session_key}, self()}, fun, [node()]) do
      :aborted -> {:error, :outcome_unknown}
      result -> result
    end
  end

  @doc false
  def ack(server \\ Store, run_id, effect), do: update(server, run_id, effect, :done, 3)

  @doc false
  def failed(server \\ Store, run_id, effect), do: update(server, run_id, effect, :failed, 3)

  defp update(_server, _run_id, _effect, _status, 0), do: {:error, :concurrent_update}

  defp update(server, run_id, effect, status, remaining) do
    with {:ok, row} when is_map(row) <- pending(server, run_id) do
      replacement =
        case {Map.fetch!(row, effect), status} do
          {:done, _} -> row
          {_, :failed} -> row |> Map.put(effect, :failed) |> count_failure(effect)
          {_, :done} -> Map.put(row, effect, :done)
        end

      result =
        if Enum.all?([:notification, :projections, :presentation], &(replacement[&1] == :done)) do
          Store.compare_and_delete(server, @table, run_id, row)
        else
          if replacement == row,
            do: :ok,
            else: Store.compare_and_swap(server, @table, run_id, row, replacement, durable: true)
        end

      case result do
        {:error, :mismatch} -> update(server, run_id, effect, status, remaining - 1)
        other -> other
      end
    else
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp count_failure(row, effect) do
    counts = Map.get(row, :failures, %{})
    count = min(Map.get(counts, effect, 0) + 1, @max_auto_attempts)
    Map.put(row, :failures, Map.put(counts, effect, count))
  end

  @doc false
  def publish(server \\ Store, run_id, %Event{} = event) do
    meta =
      (event.meta || %{})
      |> Map.put(:run_id, run_id)
      |> Map.put(:event_id, "run_completed:#{run_id}")

    event = %{event | meta: meta}

    with :ok <- Bus.broadcast(Bus.run_topic(run_id), event) do
      # Publishing succeeded; if acknowledging fails replay can duplicate it.
      _ = ack(server, run_id, :notification)
      :ok
    end
  end

  @doc false
  def event(run_id, %{completed: completed} = summary) when is_map(completed) do
    Event.new(
      :run_completed,
      Events.RunCompleted.new(%{
        completed: Events.Completion.from_map(completed),
        duration_ms: summary[:duration_ms]
      }),
      %{
        run_id: run_id,
        session_key: summary[:session_key],
        engine: summary[:engine],
        event_id: "run_completed:#{run_id}"
      }
    )
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :replay, @interval_ms)

    {:ok,
     %{
       cursor: nil,
       boot_ms: System.system_time(:millisecond),
       store: Keyword.get(opts, :store, Store)
     }}
  end

  @impl true
  def handle_info(:replay, state) do
    cutoff = max(System.system_time(:millisecond) - @live_grace_ms, state.boot_ms)

    cursor =
      case Store.terminal_pending_page(state.store, state.cursor, @batch_size) do
        {:ok, rows} ->
          Enum.each(rows, &replay(state.store, &1, cutoff))
          if length(rows) == @batch_size, do: elem(List.last(rows), 0), else: nil

        {:error, _} ->
          state.cursor
      end

    Process.send_after(self(), :replay, @interval_ms)
    {:noreply, %{state | cursor: cursor}}
  end

  defp replay(server, {run_id, %{digest: digest}}, cutoff) do
    with {:ok, %{digest: ^digest, committed_at_ms: committed}} when committed <= cutoff <-
           decision(server, run_id) do
      with_pending(server, run_id, fn
        %{digest: ^digest} = row ->
          if row.notification != :done do
            publish(server, run_id, event(run_id, row.record.summary))
          end

          if retryable?(row, :projections), do: repair_projections(server, run_id, row)
          if retryable?(row, :presentation), do: repair_presentation(server, run_id, row.record)

        _ ->
          :ok
      end)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp retryable?(row, effect) do
    Map.fetch!(row, effect) != :done and
      Map.get(Map.get(row, :failures, %{}), effect, 0) < @max_auto_attempts
  end

  defp repair_presentation(server, run_id, record) do
    case Application.get_env(:lemon_core, :terminal_presentation_replayer) do
      {module, function} ->
        case apply(module, function, [run_id, record]) do
          :ok -> ack(server, run_id, :presentation)
          :busy -> {:error, :presentation_busy}
          {:error, _} -> presentation_failed(server, run_id)
        end

      nil ->
        {:error, :presentation_unavailable}
    end
  rescue
    _ -> presentation_failed(server, run_id)
  catch
    :exit, _ -> presentation_failed(server, run_id)
  end

  defp presentation_failed(server, run_id) do
    _ = failed(server, run_id, :presentation)
    {:error, :presentation_failed}
  end
end
