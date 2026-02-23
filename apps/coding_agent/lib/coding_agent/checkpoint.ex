defmodule CodingAgent.Checkpoint do
  @moduledoc """
  Checkpoint and resume mechanism for long-running agents.

  This module provides functionality to save and restore agent session state,
  enabling agents to resume work after interruptions or failures.

  ## Usage

      # Create a checkpoint
      {:ok, checkpoint} = Checkpoint.create("session-123", context: %{step: 5})

      # Later, resume from checkpoint
      {:ok, state} = Checkpoint.resume(checkpoint.id)

      # List all checkpoints for a session
      checkpoints = Checkpoint.list("session-123")

  ## Storage

  Checkpoints are stored as JSON files in the system temp directory under
  `lemon_checkpoints/`. Each checkpoint includes:
  - Session state (messages, context)
  - Todo list state
  - Feature requirements progress
  - Metadata (timestamp, tags)

  """

  require Logger

  @checkpoint_dir Path.join([System.tmp_dir!(), "lemon_checkpoints"])
  @checkpoint_version "1.0"

  @type checkpoint :: %{
          id: String.t(),
          session_id: String.t(),
          timestamp: String.t(),
          state: map(),
          context: map(),
          todos: list(),
          requirements: map() | nil,
          metadata: map()
        }

  @doc """
  Create a checkpoint of current session state.

  ## Parameters

    * `session_id` - The session ID to checkpoint
    * `opts` - Optional parameters:
      * `:context` - Additional context to save (map)
      * `:metadata` - Metadata tags (map)
      * `:todos` - Override todo list (defaults to TodoStore.get)
      * `:requirements` - Override requirements (defaults to FeatureRequirements.load)

  ## Returns

    * `{:ok, checkpoint}` - The created checkpoint
    * `{:error, reason}` - If checkpoint creation fails

  ## Examples

      {:ok, checkpoint} = Checkpoint.create("session-123")
      checkpoint.id
      # => "chk_a1b2c3d4"

      {:ok, checkpoint} = Checkpoint.create("session-123",
        context: %{current_step: 5},
        metadata: %{tag: "before_api_call"}
      )
  """
  @spec create(String.t(), keyword()) :: {:ok, checkpoint()} | {:error, term()}
  def create(session_id, opts \\ []) when is_binary(session_id) do
    checkpoint = %{
      id: generate_checkpoint_id(),
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      state: opts[:state] || %{},
      context: opts[:context] || %{},
      todos: opts[:todos] || CodingAgent.Tools.TodoStore.get(session_id),
      requirements: opts[:requirements] || load_requirements(session_id),
      metadata: Map.merge(%{version: @checkpoint_version}, opts[:metadata] || %{})
    }

    case save_checkpoint(checkpoint) do
      :ok ->
        Logger.debug("Created checkpoint #{checkpoint.id} for session #{session_id}")
        {:ok, checkpoint}

      {:error, reason} ->
        Logger.error("Failed to create checkpoint: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Resume from a checkpoint.

  Restores the todo list and returns the checkpoint state for the agent
  to resume work.

  ## Parameters

    * `checkpoint_id` - The ID of the checkpoint to resume from

  ## Returns

    * `{:ok, resume_state}` - State to resume from
    * `{:error, :not_found}` - Checkpoint doesn't exist
    * `{:error, reason}` - Other errors

  ## Resume State Structure

      %{
        session_id: "session-123",
        state: %{...},           # Original state
        context: %{...},         # Context at checkpoint
        todos: [...],            # Restored todo list
        requirements: %{...},    # Feature requirements
        resumed_from: "chk_...", # Checkpoint ID
        timestamp: "2026-..."    # Original checkpoint time
      }

  """
  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(checkpoint_id) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load_checkpoint(checkpoint_id) do
      # Restore todos
      CodingAgent.Tools.TodoStore.put(checkpoint.session_id, checkpoint.todos)

      # Return resume context
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

  @doc """
  List checkpoints for a session.

  Returns all checkpoints sorted by timestamp (newest first).

  ## Parameters

    * `session_id` - The session ID to list checkpoints for

  ## Returns

    * List of checkpoints

  """
  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) when is_binary(session_id) do
    ensure_checkpoint_dir()

    @checkpoint_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(fn filename ->
      path = Path.join(@checkpoint_dir, filename)

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content, keys: :atoms!) do
            {:ok, checkpoint} -> checkpoint
            _ -> nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  @doc """
  Get the most recent checkpoint for a session.

  ## Parameters

    * `session_id` - The session ID

  ## Returns

    * `{:ok, checkpoint}` - The most recent checkpoint
    * `{:error, :not_found}` - No checkpoints exist

  """
  @spec get_latest(String.t()) :: {:ok, checkpoint()} | {:error, :not_found}
  def get_latest(session_id) when is_binary(session_id) do
    case list(session_id) do
      [] -> {:error, :not_found}
      [latest | _] -> {:ok, latest}
    end
  end

  @doc """
  Delete a checkpoint.

  ## Parameters

    * `checkpoint_id` - The checkpoint ID to delete

  ## Returns

    * `:ok` - Successfully deleted
    * `{:error, reason}` - If deletion fails

  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(checkpoint_id) when is_binary(checkpoint_id) do
    path = checkpoint_path(checkpoint_id)

    case File.rm(path) do
      :ok ->
        Logger.debug("Deleted checkpoint #{checkpoint_id}")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete all checkpoints for a session.

  ## Parameters

    * `session_id` - The session ID

  ## Returns

    * `{:ok, count}` - Number of checkpoints deleted

  """
  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(session_id) when is_binary(session_id) do
    checkpoints = list(session_id)

    Enum.each(checkpoints, fn checkpoint ->
      delete(checkpoint.id)
    end)

    {:ok, length(checkpoints)}
  end

  @doc """
  Get checkpoint statistics for a session.

  ## Parameters

    * `session_id` - The session ID

  ## Returns

    * Map with statistics:
      * `:count` - Number of checkpoints
      * `:oldest` - Timestamp of oldest checkpoint
      * `:newest` - Timestamp of newest checkpoint

  """
  @spec stats(String.t()) :: map()
  def stats(session_id) when is_binary(session_id) do
    checkpoints = list(session_id)

    case checkpoints do
      [] ->
        %{count: 0, oldest: nil, newest: nil}

      _ ->
        timestamps = Enum.map(checkpoints, & &1.timestamp)

        %{
          count: length(checkpoints),
          oldest: List.last(timestamps),
          newest: hd(timestamps)
        }
    end
  end

  @doc """
  Check if a checkpoint exists.

  ## Parameters

    * `checkpoint_id` - The checkpoint ID

  ## Returns

    * `true` - Checkpoint exists
    * `false` - Checkpoint doesn't exist

  """
  @spec exists?(String.t()) :: boolean()
  def exists?(checkpoint_id) when is_binary(checkpoint_id) do
    checkpoint_path(checkpoint_id)
    |> File.exists?()
  end

  @doc """
  Prune old checkpoints for a session.

  Keeps only the most recent `keep` checkpoints.

  ## Parameters

    * `session_id` - The session ID
    * `keep` - Number of checkpoints to keep (default: 10)

  ## Returns

    * `{:ok, deleted_count}` - Number of checkpoints deleted

  """
  @spec prune(String.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune(session_id, keep \\ 10) when is_binary(session_id) and is_integer(keep) and keep >= 0 do
    checkpoints = list(session_id)

    to_delete = Enum.drop(checkpoints, keep)

    Enum.each(to_delete, fn checkpoint ->
      delete(checkpoint.id)
    end)

    {:ok, length(to_delete)}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_checkpoint_id do
    "chk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp checkpoint_path(checkpoint_id) do
    Path.join(@checkpoint_dir, "#{checkpoint_id}.json")
  end

  defp ensure_checkpoint_dir do
    File.mkdir_p!(@checkpoint_dir)
  end

  defp save_checkpoint(checkpoint) do
    ensure_checkpoint_dir()
    path = checkpoint_path(checkpoint.id)

    content = Jason.encode!(checkpoint, pretty: true)
    File.write(path, content)
  end

  defp load_checkpoint(checkpoint_id) do
    path = checkpoint_path(checkpoint_id)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms!) do
          {:ok, checkpoint} -> {:ok, checkpoint}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_requirements(session_id) do
    # Try to infer the project directory from session_id
    # This is a heuristic - in practice, the session would store its cwd
    case CodingAgent.Tools.FeatureRequirements.load_requirements(".") do
      {:ok, req} -> req
      {:error, _} -> nil
    end
  end
end
