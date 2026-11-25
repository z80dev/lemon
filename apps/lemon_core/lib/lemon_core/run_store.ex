defmodule LemonCore.RunStore do
  @moduledoc """
  Typed wrapper for run lifecycle and history persistence.

  Runs live in the `:runs` table and each session's summary row in
  `:sessions_index`. Writes go through `LemonCore.Store`'s serialized run
  lifecycle path. Finalization is synchronous, retry-safe, and keeps its
  summary immutable; see `finalize/3` for the hook delivery contract.
  """

  alias LemonCore.Store
  alias LemonCore.RunHistoryStore

  @spec get(binary()) :: term()
  def get(run_id), do: Store.get_run(run_id)

  @doc """
  Fetch a run without treating an unavailable store as a missing record.

  `{:error, :evicted}` is a run that was finalized and whose record has since
  passed its retention: treat it as finished, never as absent.
  """
  @spec fetch(binary()) :: {:ok, map() | nil} | {:error, :evicted | :store_unavailable}
  def fetch(run_id), do: Store.fetch_run(run_id)

  @doc "Fetch one durable session index without confusing owner failure with absence."
  def fetch_session_index(session_key), do: Store.fetch(:sessions_index, session_key)

  @doc """
  Fetch the exact native session incarnation, backfilling legacy indexes by CAS.

  The opaque token is durable and independent of wall-clock timestamps. A
  missing index is never created by this operation; a concurrent delete or
  update makes the backfill retry against the latest strictly fetched row.
  """
  @spec ensure_session_incarnation(binary()) :: {:ok, map()} | {:error, atom()}
  def ensure_session_incarnation(session_key), do: ensure_session_incarnation(session_key, 64)

  defp ensure_session_incarnation(_session_key, 0), do: {:error, :session_busy}

  defp ensure_session_incarnation(session_key, attempts) do
    case fetch_session_index(session_key) do
      {:ok, %{session_key: ^session_key} = index} ->
        case Map.fetch(index, :incarnation) do
          {:ok, token} when is_binary(token) and byte_size(token) == 22 ->
            {:ok, index}

          :error ->
            updated = Map.put(index, :incarnation, new_session_incarnation())

            case Store.compare_and_swap(:sessions_index, session_key, index, updated) do
              :ok -> {:ok, updated}
              {:error, :mismatch} -> ensure_session_incarnation(session_key, attempts - 1)
              {:error, _} -> {:error, :store_unavailable}
            end

          _invalid ->
            {:error, :invalid_session}
        end

      {:ok, nil} ->
        {:error, :not_found}

      {:ok, _invalid} ->
        {:error, :invalid_session}

      {:error, _} ->
        {:error, :store_unavailable}
    end
  end

  @spec append_event(term(), term()) :: :ok | {:error, term()}
  def append_event(run_id, event), do: Store.append_run_event(run_id, execution_projection(event))

  @doc """
  Finalize a run synchronously.

  `:ok` means both the immutable final summary and its derived session index
  were written. Retrying the same summary repairs partial index failures
  without double-counting the run, provided fewer than 32 newer runs of the
  same session were indexed in between (the session entry remembers only its
  most recent run ids, so its size stays fixed). Finalize hooks use
  at-least-once delivery, so hook implementations must be idempotent by run id.
  """
  @spec finalize(Store.server(), term(), map()) :: :ok | {:error, term()}
  def finalize(server \\ Store, run_id, summary),
    do: Store.finalize_run(server, run_id, execution_projection(summary))

  @doc """
  Recent run history for display. Returns `[]` when the history owner cannot
  answer; use `fetch_history/2` where unavailability must not look empty.
  """
  @spec history(term(), keyword()) :: list()
  def history(session_key, opts \\ []), do: RunHistoryStore.get(session_key, opts)

  @doc "Recent run history, or an error when the owner cannot read or decode it."
  @spec fetch_history(term(), keyword()) :: {:ok, list()} | {:error, term()}
  def fetch_history(session_key, opts \\ []), do: RunHistoryStore.fetch(session_key, opts)

  @doc "Count retained run-history rows for a session, failing closed on owner error."
  @spec fetch_history_count(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def fetch_history_count(session_key), do: RunHistoryStore.fetch_count(session_key)

  @doc "Session index rows for display; `[]` when the Store cannot answer."
  @spec list_sessions(Store.server()) :: [{term(), map()}]
  def list_sessions(server \\ Store) do
    server
    |> Store.list(:sessions_index)
    |> Enum.map(fn {session_key, entry} -> {session_key, public_session_entry(entry)} end)
  end

  @doc "Every session index row, or `{:error, :store_unavailable}` when unreadable."
  @spec fetch_sessions(Store.server()) ::
          {:ok, [{term(), map()}]} | {:error, :store_unavailable}
  def fetch_sessions(server \\ Store) do
    with {:ok, entries} <- Store.fetch_all(server, :sessions_index) do
      {:ok, Enum.map(entries, fn {key, entry} -> {key, public_session_entry(entry)} end)}
    end
  end

  @doc """
  Every indexed session key, strictly. Served from the session index's read
  cache (or a key read of the backend) without copying the rows.
  """
  @spec fetch_session_keys(Store.server()) :: {:ok, [term()]} | {:error, :store_unavailable}
  def fetch_session_keys(server \\ Store), do: Store.fetch_keys(server, :sessions_index)

  @doc "Create an empty durable session index without manufacturing a completed run."
  @spec create_session_index(String.t(), String.t(), atom()) :: :ok | {:error, term()}
  def create_session_index(session_key, agent_id, origin) do
    now = System.system_time(:millisecond)

    Store.put_new(:sessions_index, session_key, %{
      session_key: session_key,
      incarnation: new_session_incarnation(),
      agent_id: agent_id,
      origin: origin,
      created_at_ms: now,
      updated_at_ms: now,
      run_count: 0,
      __recent_run_ids__: []
    })
  end

  @spec delete_session_index(term()) :: :ok | {:error, term()}
  def delete_session_index(session_key), do: Store.delete(:sessions_index, session_key)

  @doc "Delete a session's run history; see `LemonCore.RunHistoryStore.delete_session/2`."
  @spec delete_history(term()) :: :ok | {:error, atom()}
  def delete_history(session_key) do
    cutoff = System.monotonic_time()
    result = RunHistoryStore.delete_session(session_key)

    if result == :ok,
      do:
        LemonCore.Bus.broadcast(
          "sessions:lifecycle",
          {:session_history_deleted, session_key, cutoff}
        )

    result
  end

  @doc """
  Delete a session's index row, then its history. A history failure after the
  index was deleted is `{:error, :outcome_unknown}`: the deletion partly applied.
  """
  @spec delete_session(term()) :: :ok | {:error, term()}
  def delete_session(session_key) do
    with :ok <- delete_session_index(session_key) do
      case delete_history(session_key) do
        :ok -> :ok
        {:error, _reason} -> {:error, :outcome_unknown}
      end
    end
  end

  defp new_session_incarnation,
    do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @doc "Remove invocation-only configuration before persistence or management projection."
  @spec execution_projection(term()) :: term()
  def execution_projection(%_{} = value) do
    Map.merge(value, execution_projection(Map.from_struct(value)))
  end

  def execution_projection(value) when is_map(value) do
    value
    |> Map.drop([
      :tern_pane,
      "tern_pane",
      :mcp_servers,
      "mcp_servers",
      :mcpServers,
      "mcpServers",
      :mcp_servers_json,
      "mcp_servers_json",
      :native_lineage_handle,
      "native_lineage_handle",
      :nativeLineageHandle,
      "nativeLineageHandle",
      :native_destination_pid,
      "native_destination_pid",
      :nativeDestinationPid,
      "nativeDestinationPid",
      :native_destination_generation,
      "native_destination_generation",
      :nativeDestinationGeneration,
      "nativeDestinationGeneration"
    ])
    |> Map.new(fn {key, entry} -> {key, execution_projection(entry)} end)
  end

  def execution_projection(value) when is_list(value),
    do: Enum.map(value, &execution_projection/1)

  def execution_projection(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&execution_projection/1) |> List.to_tuple()

  def execution_projection(value), do: value

  # `:__recent_run_ids__` is the store's bounded finalization-idempotency
  # marker; the other two are the unbounded marker it replaced, still present on
  # entries whose session has not finalized a run since.
  defp public_session_entry(entry) when is_map(entry) do
    Map.drop(entry, [:__recent_run_ids__, :__indexed_run_ids__, :__legacy_run_count__])
  end

  defp public_session_entry(entry), do: entry
end
