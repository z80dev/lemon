defmodule LemonCore.ProgressStore do
  @moduledoc """
  Maps a channel's progress message back to the run that produced it.

  Owns the `:progress` table, keyed by `{scope, progress_msg_id}` and
  mirrored into the read cache: adapters resolve a message id to a run on
  every control interaction, far more often than they write one.

  Writes are synchronous: when `put/4` returns, a read cannot observe the
  previous value.
  """

  use LemonCore.Store.Table, tables: [progress: [cached: true]]

  alias LemonCore.Store

  @table :progress

  @spec put(Store.server(), term(), integer(), term()) :: :ok | {:error, term()}
  def put(server \\ Store, scope, progress_msg_id, run_id) do
    Store.put(server, @table, {scope, progress_msg_id}, run_id)
  end

  @doc "The run id a progress message belongs to, or `nil`."
  @spec get_run(Store.server(), term(), integer()) :: term() | nil
  def get_run(server \\ Store, scope, progress_msg_id) do
    Store.get(server, @table, {scope, progress_msg_id})
  end

  @spec delete(Store.server(), term(), integer()) :: :ok | {:error, term()}
  def delete(server \\ Store, scope, progress_msg_id) do
    Store.delete(server, @table, {scope, progress_msg_id})
  end
end
