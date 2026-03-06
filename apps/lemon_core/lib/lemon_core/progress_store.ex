defmodule LemonCore.ProgressStore do
  @moduledoc """
  Typed wrapper for progress-message to run mapping.
  """

  alias LemonCore.Store

  @spec put(term(), integer() | binary(), binary()) :: :ok | {:error, term()}
  def put(scope, progress_msg_id, run_id), do: Store.put_progress_mapping(scope, progress_msg_id, run_id)

  @spec get_run(term(), integer() | binary()) :: binary() | nil
  def get_run(scope, progress_msg_id), do: Store.get_run_by_progress(scope, progress_msg_id)

  @spec delete(term(), integer() | binary()) :: :ok | {:error, term()}
  def delete(scope, progress_msg_id), do: Store.delete_progress_mapping(scope, progress_msg_id)
end
