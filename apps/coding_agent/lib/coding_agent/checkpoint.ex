defmodule CodingAgent.Checkpoint do
  @moduledoc """
  Coding-agent filesystem checkpoint operations backed by `LemonCore.Checkpoint`.
  """

  alias LemonCore.Checkpoint, as: CoreCheckpoint

  @type checkpoint :: CoreCheckpoint.checkpoint()
  @type filesystem_snapshot :: CoreCheckpoint.filesystem_snapshot()

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

  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) when is_binary(session_id), do: CoreCheckpoint.list(session_id)

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(checkpoint_id, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.delete(checkpoint_id, opts)

  @spec stats(String.t()) :: map()
  def stats(session_id) when is_binary(session_id), do: CoreCheckpoint.stats(session_id)

end
