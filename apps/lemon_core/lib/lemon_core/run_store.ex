defmodule LemonCore.RunStore do
  @moduledoc """
  Typed wrapper for run lifecycle and history persistence.
  """

  alias LemonCore.Store
  alias LemonCore.RunHistoryStore

  @spec get(binary()) :: term()
  def get(run_id), do: Store.get_run(run_id)

  @spec append_event(term(), term()) :: :ok | {:error, term()}
  def append_event(run_id, event), do: Store.append_run_event(run_id, event)

  @spec finalize(term(), term()) :: :ok | {:error, term()}
  def finalize(run_id, summary), do: Store.finalize_run(run_id, summary)

  @spec history(term(), keyword()) :: list()
  def history(session_key, opts \\ []), do: RunHistoryStore.get(session_key, opts)

  @spec list_sessions() :: [{term(), map()}]
  def list_sessions, do: Store.list(:sessions_index)

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
end
