defmodule CodingAgent.FileReadTracker do
  @moduledoc """
  Per-session record of file contents the agent has seen, used to reject
  edits against a stale view of a file.

  `read` records a digest of the file it returned; `write`, `edit`, and
  `patch` refresh the digest after their own writes. Text `edit` calls `check/3`
  before applying a replacement: when the session has a recorded digest for
  the file and the bytes on disk no longer match it, the file was changed
  behind the agent's back (by the user, a formatter, `bash`, or another
  session) and the edit is refused with a "re-read the file" error.

  Recent raw-line snapshots are retained for safe anchored-edit recovery: up to
  eight per path, limited to 256 KiB and 10,000 lines each. Oversized files retain
  digest-only staleness tracking. Snapshot entries share session cleanup.

  Tracking is scoped by the `:session_id` tool option. Tool calls without a
  session id (direct calls, scripts) are not tracked. When the tool options
  carry `:session_pid`, the session's entries are dropped when that process
  exits.
  """

  use GenServer

  @table :coding_agent_file_read_tracker
  @snapshots :coding_agent_file_snapshots
  @snapshot_limit 8
  @snapshot_bytes 256 * 1024
  @snapshot_lines 10_000

  @doc false
  def snapshot_byte_limit, do: @snapshot_bytes

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record `content` as the session's current view of `path`.
  """
  @spec record(keyword(), String.t(), binary()) :: :ok
  def record(opts, path, content) when is_binary(path) and is_binary(content) do
    content_digest = digest(content)
    record_digest(opts, path, content_digest)

    with {:ok, scope} <- scope(opts),
         true <- table_ready?(),
         true <- byte_size(content) <= @snapshot_bytes,
         true <- length(:binary.matches(content, "\n")) <= @snapshot_lines do
      tag = CodingAgent.Tools.AnchoredEdit.snapshot_for_digest(content_digest)
      lines = CodingAgent.Tools.AnchoredEdit.lines(content)
      GenServer.call(__MODULE__, {:snapshot, {scope, Path.expand(path)}, tag, lines})
    end

    :ok
  end

  @doc false
  @spec record_digest(keyword(), String.t(), binary()) :: :ok
  def record_digest(opts, path, digest) when is_binary(path) and is_binary(digest) do
    with {:ok, scope} <- scope(opts),
         true <- table_ready?() do
      :ets.insert(@table, {{scope, Path.expand(path)}, digest})
      watch(scope, Keyword.get(opts, :session_pid))
    end

    :ok
  end

  @doc "Look up raw lines from a recent session/path snapshot, or return nil."
  def snapshot_lines(opts, path, tag) do
    with {:ok, scope} <- scope(opts),
         true <- table_ready?(),
         [{_key, snapshots}] <- :ets.lookup(@snapshots, {scope, Path.expand(path)}) do
      case List.keyfind(snapshots, String.upcase(tag), 0) do
        {_tag, lines} -> lines
        nil -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Refresh the session's view of each path from disk (after the agent wrote
  them). Paths that no longer exist are forgotten.
  """
  @spec refresh(keyword(), [String.t()]) :: :ok
  def refresh(opts, paths) when is_list(paths) do
    with {:ok, scope} <- scope(opts),
         true <- table_ready?() do
      Enum.each(paths, fn path ->
        case File.read(path) do
          {:ok, content} ->
            record(opts, path, content)

          {:error, _} ->
            :ets.delete(@table, {scope, Path.expand(path)})
            :ets.delete(@snapshots, {scope, Path.expand(path)})
        end
      end)
    end

    :ok
  end

  @doc """
  Check `current_content` (just read from disk) against the session's
  recorded view of `path`. Files the session never read pass.
  """
  @spec check(keyword(), String.t(), binary()) :: :ok | {:error, :stale}
  def check(opts, path, current_content) when is_binary(path) and is_binary(current_content) do
    with {:ok, scope} <- scope(opts),
         true <- table_ready?(),
         [{_key, recorded}] <- :ets.lookup(@table, {scope, Path.expand(path)}) do
      if recorded == digest(current_content), do: :ok, else: {:error, :stale}
    else
      _ -> :ok
    end
  end

  @doc "Drop every entry recorded for a session id."
  @spec forget_session(String.t()) :: :ok
  def forget_session(session_id) do
    if table_ready?() do
      :ets.match_delete(@table, {{session_id, :_}, :_})
      :ets.match_delete(@snapshots, {{session_id, :_}, :_})
    end

    :ok
  end

  defp scope(opts) do
    case Keyword.get(opts, :session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :untracked
    end
  end

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp digest(content), do: :erlang.md5(content)

  defp watch(scope, pid) when is_pid(pid), do: GenServer.cast(__MODULE__, {:watch, scope, pid})
  defp watch(_scope, _pid), do: :ok

  # Server

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@snapshots, [:named_table, :public, :set, read_concurrency: true])

    {:ok, %{watched: %{}}}
  end

  @impl true
  def handle_call({:snapshot, key, tag, lines}, _from, state) do
    snapshots =
      case :ets.lookup(@snapshots, key) do
        [{^key, snapshots}] -> snapshots
        [] -> []
      end

    snapshots = [{tag, lines} | List.keydelete(snapshots, tag, 0)] |> Enum.take(@snapshot_limit)
    :ets.insert(@snapshots, {key, snapshots})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:watch, scope, pid}, state) do
    if Map.has_key?(state.watched, scope) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      {:noreply, %{state | watched: Map.put(state.watched, scope, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.watched, fn {_scope, watched_ref} -> watched_ref == ref end) do
      {scope, _} ->
        forget_session(scope)
        {:noreply, %{state | watched: Map.delete(state.watched, scope)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
