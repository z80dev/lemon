defmodule CodingAgent.Checkpoint do
  @moduledoc """
  Coding-agent filesystem checkpoint operations backed by `LemonAgent.Checkpoint`.

  Checkpoint ownership is the trusted session id (`session.header.id`) that the
  session places in tool options as `:session_id`. `owner/1` is the single
  resolver used both when capturing (`CodingAgent.Tools.CheckpointGuard`) and
  when accessing (`CodingAgent.Tools.FsCheckpoint`). It never falls back to
  `:session_key` or `:run_id`: those can be selected by task parameters, so a
  child given another session's key cannot become that session's owner.
  Subagent/task children run in their own sessions and therefore own their own
  checkpoints; they do not share the parent's.
  """

  alias CodingAgent.Tools.OperatorState
  alias LemonAgent.Checkpoint, as: CoreCheckpoint

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

  @doc """
  Owner-scoped restore for the model-facing `fs_checkpoint` tool.

  Checkpoint files live outside Lemon's control (the system temp directory by
  default), so their recorded roots are untrusted: each selected root goes
  through `CodingAgent.Tools.OperatorState.check_mutation/2` first, and only
  the checked roots are handed to `LemonAgent.Checkpoint.restore_filesystem/3`.
  """
  @spec restore_filesystem(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_filesystem(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, paths} <- restorable_paths(checkpoint_id, owner, opts[:paths]) do
      CoreCheckpoint.restore_filesystem(checkpoint_id, owner, Keyword.put(opts, :paths, paths))
    end
  end

  # Ownership and snapshot errors come from the core restore itself.
  defp restorable_paths(checkpoint_id, owner, selected) do
    with {:ok, %{session_id: ^owner} = checkpoint} <- CoreCheckpoint.load(checkpoint_id),
         {:ok, files} <- CoreCheckpoint.confined_filesystem_files(checkpoint) do
      paths =
        if is_list(selected),
          do: selected |> Enum.map(&Path.expand/1) |> Enum.uniq(),
          else: Enum.map(files, & &1.path)

      Enum.reduce_while(paths, {:ok, paths}, fn path, acc ->
        case OperatorState.check_mutation(path) do
          :ok -> {:cont, acc}
          {:error, reason} -> {:halt, {:error, {:operator_state, reason}}}
        end
      end)
    else
      _ -> {:ok, selected}
    end
  end

  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) when is_binary(session_id), do: CoreCheckpoint.list(session_id)

  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id),
    do: CoreCheckpoint.delete(checkpoint_id, owner, opts)

  @spec stats(String.t()) :: map()
  def stats(session_id) when is_binary(session_id), do: CoreCheckpoint.stats(session_id)
end
