defmodule LemonCore.TerminalOutbox do
  @moduledoc """
  Bounded replay of committed run completions. Notification and projections
  have independent acknowledgements; no acknowledgement can rewrite a decision.
  Normal publication is serialized and happens once. A crash between broadcast
  and its durable acknowledgement can cause replay with the same `meta.event_id`.
  """
  use GenServer

  alias LemonCore.{Bus, Event, Events, Store}

  @table :run_terminal_pending
  @batch_size 8
  @interval_ms 5_000
  @live_grace_ms 30_000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Read the immutable, content-free decision, independently of volatile run data."
  def decision(server \\ Store, run_id), do: Store.fetch(server, :run_terminals, run_id)

  @doc "Read the committed replay source while an effect remains unacknowledged."
  def pending(server \\ Store, run_id), do: Store.terminal_pending(server, run_id)

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
        _ = Store.update_terminal_effect(server, run_id, :projections, :failed)
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

      {:ok, %{}} ->
        # Session-less completions still serialize live notification with replay.
        session_lock(server, {:run, run_id}, fn ->
          with {:ok, row} <- pending(server, run_id), do: fun.(row)
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
    case :global.trans({{__MODULE__, server, session_key}, self()}, fun, [node()], 3) do
      :aborted -> {:error, :outcome_unknown}
      result -> result
    end
  end

  @doc false
  def publish(server \\ Store, run_id, %Event{type: :run_completed, ts_ms: ts_ms}) do
    with_pending(server, run_id, &publish_pending(server, run_id, &1, ts_ms))
  end

  defp publish_pending(
         server,
         run_id,
         %{notification: status, record: %{summary: summary}},
         ts_ms
       )
       when status != :done do
    with {:ok, %{attempt_id: attempt_id}} <- decision(server, run_id),
         event = completion_event(run_id, summary, ts_ms),
         :ok <- Bus.publish_run_lifecycle(Event.identify_run(event, run_id, attempt_id)) do
      # Publishing succeeded; if acknowledging fails replay can duplicate it.
      _ = Store.update_terminal_effect(server, run_id, :notification, :done)
      :ok
    end
  end

  defp publish_pending(_server, _run_id, _row, _ts_ms), do: :ok

  @doc false
  def event(run_id, %{completed: completed} = summary) when is_map(completed) do
    run_id
    |> completion_event(summary, Event.now_ms())
    |> Event.identify_run(run_id, summary[:attempt_id])
  end

  defp completion_event(run_id, summary, ts_ms) do
    meta =
      Map.merge(summary[:terminal_event_meta] || %{}, %{
        run_id: run_id,
        session_key: summary[:session_key],
        engine: summary[:engine]
      })

    Event.new_with_ts(
      :run_completed,
      summary[:completed_at_ms] || ts_ms,
      Events.RunCompleted.new(%{
        completed: Events.Completion.from_map(summary.completed),
        duration_ms: summary[:duration_ms]
      }),
      meta
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
          publish_pending(server, run_id, row, Event.now_ms())

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
      Map.get(Map.get(row, :failures, %{}), effect, 0) < Store.terminal_effect_retry_limit()
  end

  defp repair_presentation(server, run_id, record) do
    case Application.get_env(:lemon_core, :terminal_presentation_replayer) do
      {module, function} ->
        case apply(module, function, [run_id, record]) do
          :ok -> Store.update_terminal_effect(server, run_id, :presentation, :done)
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
    _ = Store.update_terminal_effect(server, run_id, :presentation, :failed)
    {:error, :presentation_failed}
  end
end
