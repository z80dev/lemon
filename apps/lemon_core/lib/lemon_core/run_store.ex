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
  """
  @spec fetch(binary()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch(run_id), do: Store.fetch_run(run_id)

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

  @spec history(term(), keyword()) :: list()
  def history(session_key, opts \\ []), do: RunHistoryStore.get(session_key, opts)

  @spec list_sessions(Store.server()) :: [{term(), map()}]
  def list_sessions(server \\ Store) do
    server
    |> Store.list(:sessions_index)
    |> Enum.map(fn {session_key, entry} -> {session_key, public_session_entry(entry)} end)
  end

  @doc "Create an empty durable session index without manufacturing a completed run."
  @spec create_session_index(String.t(), String.t(), atom()) :: :ok | {:error, term()}
  def create_session_index(session_key, agent_id, origin) do
    now = System.system_time(:millisecond)

    Store.put_new(:sessions_index, session_key, %{
      session_key: session_key,
      agent_id: agent_id,
      origin: origin,
      created_at_ms: now,
      updated_at_ms: now,
      run_count: 0,
      __recent_run_ids__: []
    })
  end

  @spec delete_session_index(term()) :: :ok
  def delete_session_index(session_key), do: Store.delete(:sessions_index, session_key)

  @spec delete_history(term()) :: :ok
  def delete_history(session_key) do
    RunHistoryStore.delete_session(session_key)
  end

  @spec delete_session(term()) :: :ok
  def delete_session(session_key) do
    delete_session_index(session_key)
    delete_history(session_key)
  end

  @doc "Remove execution-only MCP configuration before persistence or management projection."
  @spec execution_projection(term()) :: term()
  def execution_projection(%_{} = value) do
    Map.merge(value, execution_projection(Map.from_struct(value)))
  end

  def execution_projection(value) when is_map(value) do
    value
    |> Map.drop([
      :mcp_servers, "mcp_servers", :mcpServers, "mcpServers",
      :mcp_servers_json, "mcp_servers_json",
      :native_lineage_handle, "native_lineage_handle", :nativeLineageHandle, "nativeLineageHandle",
      :native_destination_pid, "native_destination_pid", :nativeDestinationPid, "nativeDestinationPid",
      :native_destination_generation, "native_destination_generation",
      :nativeDestinationGeneration, "nativeDestinationGeneration"
    ])
    |> Map.new(fn {key, entry} -> {key, execution_projection(entry)} end)
  end

  def execution_projection(value) when is_list(value), do: Enum.map(value, &execution_projection/1)
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
