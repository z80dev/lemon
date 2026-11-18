defmodule CodingAgent.Checkpoint do
  @moduledoc """
  Coding-agent filesystem checkpoint operations backed by `LemonCore.Checkpoint`.

  Checkpoint ownership is the trusted session id (`session.header.id`) that the
  session places in tool options as `:session_id`. `owner/1` is the single
  resolver used both when capturing (`CodingAgent.Tools.CheckpointGuard`) and
  when accessing (`CodingAgent.Tools.FsCheckpoint`). It never falls back to
  `:session_key` or `:run_id`: those can be selected by task parameters, so a
  child given another session's key cannot become that session's owner.
  Subagent/task children run in their own sessions and therefore own their own
  checkpoints; they do not share the parent's.
  """

  alias LemonCore.Checkpoint, as: CoreCheckpoint

  @type checkpoint :: CoreCheckpoint.checkpoint()
  @type filesystem_snapshot :: CoreCheckpoint.filesystem_snapshot()

  @doc "Trusted checkpoint owner from tool options: the session id, or nil."
  @spec owner(keyword()) :: String.t() | nil
  def owner(opts) when is_list(opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> session_id
      _ -> nil
    end
  end

  @spec create_filesystem(String.t(), [String.t()], keyword()) ::
          {:ok, checkpoint()} | {:error, term()}
  def create_filesystem(session_id, paths, opts \\ [])
      when is_binary(session_id) and is_list(paths) do
    CoreCheckpoint.create_filesystem(session_id, paths, opts)
  end

  @spec diff_filesystem(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff_filesystem(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.diff_filesystem(checkpoint_id, owner, opts)

  @spec restore_filesystem(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_filesystem(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.restore_filesystem(checkpoint_id, owner, opts)

  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) when is_binary(session_id), do: CoreCheckpoint.list(session_id)

  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.delete(checkpoint_id, owner, opts)

  @spec stats(String.t()) :: map()
  def stats(session_id) when is_binary(session_id), do: CoreCheckpoint.stats(session_id)
end
