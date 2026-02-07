defmodule LemonGateway.Store do
  @moduledoc """
  Backwards-compatible wrapper for the canonical store.

  The canonical implementation now lives in `LemonCore.Store` so other umbrella
  apps can depend on storage without depending on `:lemon_gateway`.

  This module remains to avoid churn in the gateway code and callers.
  """

  @type table :: atom()

  # Keep a start_link/1 for older tests/callers. LemonCore.Store is normally
  # started as part of the :lemon_core application.
  def start_link(opts) do
    case LemonCore.Store.start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defdelegate put_chat_state(scope, state), to: LemonCore.Store
  defdelegate get_chat_state(scope), to: LemonCore.Store
  defdelegate delete_chat_state(scope), to: LemonCore.Store

  defdelegate append_run_event(run_id, event), to: LemonCore.Store
  defdelegate finalize_run(run_id, summary), to: LemonCore.Store

  defdelegate put_progress_mapping(scope, progress_msg_id, run_pid), to: LemonCore.Store
  defdelegate get_run_by_progress(scope, progress_msg_id), to: LemonCore.Store
  defdelegate delete_progress_mapping(scope, progress_msg_id), to: LemonCore.Store

  defdelegate put(table, key, value), to: LemonCore.Store
  defdelegate get(table, key), to: LemonCore.Store
  defdelegate delete(table, key), to: LemonCore.Store
  defdelegate list(table), to: LemonCore.Store

  defdelegate get_run_history(scope_or_session_key, opts \\ []), to: LemonCore.Store
  defdelegate get_run(run_id), to: LemonCore.Store
end
