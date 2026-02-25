defmodule LemonGateway.Store do
  @moduledoc """
  Gateway-facing store API.

  Storage is implemented by `LemonCore.Store`; this module keeps gateway code
  organized around a domain-specific namespace.
  """

  @type table :: atom()

  def start_link(opts) do
    LemonCore.Store.start_link(opts)
  end

  defdelegate put_chat_state(scope, state), to: LemonCore.Store
  defdelegate get_chat_state(scope), to: LemonCore.Store
  defdelegate delete_chat_state(scope), to: LemonCore.Store

  defdelegate append_run_event(run_id, event), to: LemonCore.Store
  defdelegate finalize_run(run_id, summary), to: LemonCore.Store

  defdelegate put_progress_mapping(scope, progress_msg_id, run_id), to: LemonCore.Store
  defdelegate get_run_by_progress(scope, progress_msg_id), to: LemonCore.Store
  defdelegate delete_progress_mapping(scope, progress_msg_id), to: LemonCore.Store

  defdelegate put(table, key, value), to: LemonCore.Store
  defdelegate get(table, key), to: LemonCore.Store
  defdelegate delete(table, key), to: LemonCore.Store
  defdelegate list(table), to: LemonCore.Store

  defdelegate get_run_history(session_key, opts \\ []), to: LemonCore.Store
  defdelegate get_run(run_id), to: LemonCore.Store
end
