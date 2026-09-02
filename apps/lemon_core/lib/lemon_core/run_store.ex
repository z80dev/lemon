defmodule LemonCore.RunStore do
  @moduledoc """
  Typed wrapper for run lifecycle and history persistence.

  This module owns the `:runs` and `:sessions_index` table contracts while the
  existing specialized `LemonCore.Store` lifecycle path provides serialized
  writes. Finalization is synchronous, retry-safe, and keeps its summary
  immutable; see `finalize/3` for the hook delivery contract.
  """

  use LemonCore.Store.Table,
    tables: [
      runs: [cached: true, persistence: :ephemeral],
      sessions_index: [cached: true]
    ]

  alias LemonCore.Store
  alias LemonCore.RunHistoryStore

  @spec get(binary()) :: term()
  def get(run_id), do: Store.get_run(run_id)

  @spec append_event(term(), term()) :: :ok | {:error, term()}
  def append_event(run_id, event), do: Store.append_run_event(run_id, event)

  @doc """
  Finalize a run synchronously.

  `:ok` means both the immutable final record and its derived session index
  were written. Retrying the same summary repairs partial index failures
  without double-counting the run. Finalize hooks use at-least-once delivery,
  so hook implementations must be idempotent by run id.
  """
  @spec finalize(Store.server(), term(), map()) :: :ok | {:error, term()}
  def finalize(server \\ Store, run_id, summary), do: Store.finalize_run(server, run_id, summary)

  @spec history(term(), keyword()) :: list()
  def history(session_key, opts \\ []), do: RunHistoryStore.get(session_key, opts)

  @spec list_sessions(Store.server()) :: [{term(), map()}]
  def list_sessions(server \\ Store) do
    server
    |> Store.list(:sessions_index)
    |> Enum.map(fn {session_key, entry} -> {session_key, public_session_entry(entry)} end)
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

  defp public_session_entry(entry) when is_map(entry) do
    Map.drop(entry, [:__indexed_run_ids__, :__legacy_run_count__])
  end

  defp public_session_entry(entry), do: entry
end
