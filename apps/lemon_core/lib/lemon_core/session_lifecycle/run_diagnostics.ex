defmodule LemonCore.SessionLifecycle.RunDiagnostics do
  @moduledoc false
  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonCore.{IntrospectionStore, RunStore, Store}
  alias LemonCore.SessionLifecycle.StoreRows

  @impl true
  def snapshot(session_key, :delete), do: snapshot_rows(session_key, MapSet.new())

  @impl true
  def delete(_session_key, :delete, %{rows: []}), do: :ok

  def delete(_session_key, :delete, %{rows: rows}) do
    Store.compare_and_delete_many(Store, rows, durable: true)
  end

  @impl true
  def verify_deleted(session_key, :delete, snapshot) do
    with {:ok, %{rows: []}} <- snapshot_rows(session_key, snapshot.run_ids),
         :ok <- StoreRows.verify_deleted(session_key, [], snapshot.rows) do
      :ok
    else
      {:ok, _remaining} -> {:error, :run_diagnostics_remain}
      error -> error
    end
  end

  @impl true
  def restore(_session_key, :delete, %{rows: rows}) do
    Enum.reduce_while(rows, :ok, fn {table, key, value}, :ok ->
      case Store.put_new(Store, table, key, value, durable: true) do
        :ok ->
          {:cont, :ok}

        {:error, :exists} ->
          case Store.fetch(table, key) do
            {:ok, ^value} -> {:cont, :ok}
            _ -> {:halt, {:error, :run_diagnostics_restore_conflict}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  @impl true
  def commit(_session_key, :delete, %{run_ids: run_ids}) do
    Store.discard_run_event_buffers(MapSet.to_list(run_ids))
  end

  defp snapshot_rows(session_key, known_run_ids) do
    with {:ok, history} <- RunStore.fetch_history(session_key, limit: -1),
         {:ok, events} <- IntrospectionStore.fetch_rows() do
      run_ids = Enum.reduce(history, known_run_ids, fn {id, _}, ids -> MapSet.put(ids, id) end)

      run_ids =
        Enum.reduce(events, run_ids, fn
          {_key, %{session_key: ^session_key, run_id: id}}, ids when is_binary(id) ->
            MapSet.put(ids, id)

          _, ids ->
            ids
        end)

      with {:ok, runs} <- Store.fetch_session_runs(session_key, run_ids) do
        # An explicit owner beats an inferred link through an event's run ID.
        run_ids =
          Enum.reduce(runs, run_ids, fn
            {id, %{summary: %{session_key: other}}}, ids
            when is_binary(other) and other != session_key ->
              MapSet.delete(ids, id)

            {id, _}, ids ->
              MapSet.put(ids, id)
          end)

        run_rows = for {id, row} <- runs, id in run_ids, do: {:runs, id, row}

        event_rows =
          for {key, %{session_key: owner, run_id: id} = row} <- events,
              owner == session_key or (is_nil(owner) and id in run_ids),
              do: {:introspection_log, key, row}

        {:ok, %{rows: run_rows ++ event_rows, run_ids: run_ids}}
      end
    end
  end
end
