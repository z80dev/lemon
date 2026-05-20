defmodule CodingAgent.Checkpoint do
  @moduledoc """
  Coding-agent checkpoint compatibility wrapper.

  Generic checkpoint storage and filesystem rollback live in `LemonCore.Checkpoint`.
  This module adds coding-agent todo and requirement state for resume flows while
  preserving the existing public API.
  """

  alias LemonCore.Checkpoint, as: CoreCheckpoint

  @type checkpoint :: CoreCheckpoint.checkpoint()
  @type filesystem_snapshot :: CoreCheckpoint.filesystem_snapshot()

  @spec create(String.t(), keyword()) :: {:ok, checkpoint()} | {:error, term()}
  def create(session_id, opts \\ []) when is_binary(session_id) do
    CoreCheckpoint.create(
      session_id,
      Keyword.merge(
        [
          todos: opts[:todos] || CodingAgent.Tools.TodoStore.get(session_id),
          requirements: opts[:requirements] || load_requirements(session_id)
        ],
        opts
      )
    )
  end

  @spec create_filesystem(String.t(), [String.t()], keyword()) ::
          {:ok, checkpoint()} | {:error, term()}
  def create_filesystem(session_id, paths, opts \\ [])
      when is_binary(session_id) and is_list(paths) do
    CoreCheckpoint.create_filesystem(session_id, paths, opts)
  end

  @spec diff_filesystem(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff_filesystem(checkpoint_id, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.diff_filesystem(checkpoint_id, opts)

  @spec restore_filesystem(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_filesystem(checkpoint_id, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.restore_filesystem(checkpoint_id, opts)

  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(checkpoint_id) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- CoreCheckpoint.load(checkpoint_id) do
      CodingAgent.Tools.TodoStore.put(checkpoint.session_id, checkpoint.todos)

      {:ok,
       %{
         session_id: checkpoint.session_id,
         state: checkpoint.state,
         context: checkpoint.context,
         todos: checkpoint.todos,
         requirements: checkpoint.requirements,
         resumed_from: checkpoint_id,
         timestamp: checkpoint.timestamp
       }}
    end
  end

  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) when is_binary(session_id), do: CoreCheckpoint.list(session_id)

  @spec get_latest(String.t()) :: {:ok, checkpoint()} | {:error, :not_found}
  def get_latest(session_id) when is_binary(session_id), do: CoreCheckpoint.get_latest(session_id)

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(checkpoint_id, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.delete(checkpoint_id, opts)

  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(session_id) when is_binary(session_id), do: CoreCheckpoint.delete_all(session_id)

  @spec stats(String.t()) :: map()
  def stats(session_id) when is_binary(session_id), do: CoreCheckpoint.stats(session_id)

  @spec exists?(String.t()) :: boolean()
  def exists?(checkpoint_id) when is_binary(checkpoint_id),
    do: CoreCheckpoint.exists?(checkpoint_id)

  @spec prune(String.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune(session_id, keep \\ 10)
      when is_binary(session_id) and is_integer(keep) and keep >= 0,
      do: CoreCheckpoint.prune(session_id, keep)

  defp load_requirements(_session_id) do
    case CodingAgent.Tools.FeatureRequirements.load_requirements(".") do
      {:ok, req} -> req
      {:error, _} -> nil
    end
  end
end
