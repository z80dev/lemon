defmodule CodingAgent.StatePaths do
  @moduledoc "Role-local DETS paths, cross-VM ownership and redacted worker status."
  require Logger
  alias LemonCore.PidFile

  @files ~w(tasks.dets parent_questions.dets run_graph.dets processes.dets)
  @states ~w(starting online reconnecting needs_reauthorization needs_enrollment conflict)
  @reasons ~w(session_expired session_invalid node_not_found credential_rejected credential_missing credential_unreadable controller_mismatch node_name_conflict node_identity_mismatch)

  def state_dir,
    do: Application.get_env(:coding_agent, :state_dir) || CodingAgent.Config.agent_dir()

  def warn_locked(pid) do
    unless Process.get({__MODULE__, :warned_lock}) do
      Logger.warning("DETS state directory is owned by OS process #{pid}; running memory-only")
      Process.put({__MODULE__, :warned_lock}, true)
    end

    :ok
  end

  def dets_path(name), do: Path.join(state_dir(), name)

  def worker_root(name) do
    name = String.trim(name)
    if name == "", do: raise(ArgumentError, "worker name must not be blank")
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    Path.join([System.user_home!(), ".lemon", "nodes", "state", digest])
  end

  def configure_worker(name) do
    root = worker_root(name)
    started? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :coding_agent))

    if started? and state_dir() != root do
      {:error, "worker state isolation requires a fresh runtime"}
    else
      with :ok <- private_dir(root) do
        Application.put_env(:coding_agent, :state_dir, root)
        :ok
      else
        _ -> {:error, "could not prepare worker state directory"}
      end
    end
  end

  def open_dets(table, path, opts \\ []) do
    path = to_string(path)

    with :ok <- claim(Path.dirname(path)) do
      :dets.open_file(table, [file: String.to_charlist(path), type: :set] ++ opts)
    end
  end

  defp claim(dir) do
    with :ok <- File.mkdir_p(dir) do
      lock = Path.join(dir, ".lemon-state.lock")
      # An atomic directory serializes stale-file reclamation across unrelated VMs.
      # A crashed claimant fails closed: persistence is safer to lose than records.
      guard = lock <> ".claim"

      case File.mkdir(guard) do
        :ok ->
          try do
            claim_locked(lock)
          after
            File.rmdir(guard)
          end

        {:error, :eexist} ->
          {:error, {:state_dir_locked, :claiming}}

        error ->
          error
      end
    end
  end

  defp claim_locked(lock) do
    case File.read(lock) do
      {:ok, contents} ->
        pid = contents |> String.split("\n") |> hd()

        cond do
          not match?({n, ""} when n > 0, Integer.parse(pid)) ->
            {:error, {:state_dir_locked, :unknown}}

          pid == System.pid() and PidFile.live?(lock) ->
            :ok

          PidFile.live?(lock) ->
            {:error, {:state_dir_locked, pid}}

          true ->
            write_lock(lock)
        end

      {:error, :enoent} ->
        write_lock(lock)

      error ->
        error
    end
  end

  defp write_lock(path) do
    with :ok <- PidFile.write(path), do: File.chmod(path, 0o600)
  end

  def prepare_default_layout do
    dir = CodingAgent.Config.agent_dir()
    marker = Path.join(dir, ".dets-layout-v1")

    unless Application.get_env(:coding_agent, :state_dir) || File.exists?(marker) do
      result = with :ok <- claim(dir), do: rebuild(dir, marker)
      if result != :ok, do: Logger.warning("DETS layout repair incomplete; will retry next boot")
    end

    :ok
  end

  defp rebuild(dir, marker) do
    stamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()
    backup = Path.join([dir, "backups", "dets-layout-v1-" <> stamp])
    files = Enum.filter(@files, &File.exists?(Path.join(dir, &1)))

    with :ok <- private_dir(backup),
         :ok <-
           Enum.reduce_while(files, :ok, fn file, :ok ->
             dest = Path.join(backup, file)
             result = with :ok <- File.cp(Path.join(dir, file), dest), do: File.chmod(dest, 0o600)
             if result == :ok, do: {:cont, :ok}, else: {:halt, result}
           end),
         :ok <-
           Enum.reduce_while(files, :ok, fn file, :ok ->
             result =
               case open_dets(:lemon_layout_repair, Path.join(dir, file), repair: :force) do
                 {:ok, table} -> :dets.close(table)
                 error -> error
               end

             if result == :ok, do: {:cont, :ok}, else: {:halt, result}
           end) do
      atomic_write(marker, "1\n")
    end
  end

  def status_path(name), do: Path.join(worker_root(name), "worker-status.json")

  def write_status(name, map) do
    status = Map.new(map, fn {key, value} -> {to_string(key), value} end)

    status =
      Map.merge(status, %{
        "version" => 1,
        "localName" => String.trim(name),
        "osPid" => String.to_integer(System.pid())
      })

    if valid_status?(status) do
      with :ok <- private_dir(worker_root(name)),
           do: atomic_write(status_path(name), Jason.encode!(status))
    else
      {:error, :invalid}
    end
  end

  def read_status(name) do
    case File.read(status_path(name)) do
      {:ok, bytes} ->
        with {:ok, map} <- Jason.decode(bytes),
             true <- valid_status?(map),
             true <- map["localName"] == String.trim(name) do
          {:ok, map}
        else
          _ -> {:error, :invalid}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      _ ->
        {:error, :invalid}
    end
  end

  defp valid_status?(map) when is_map(map) do
    Enum.sort(Map.keys(map)) ==
      Enum.sort(~w(version localName state reason nodeId changedAtMs osPid)) and
      map["version"] == 1 and is_binary(map["localName"]) and map["state"] in @states and
      map["reason"] in [nil | @reasons] and (is_nil(map["nodeId"]) or is_binary(map["nodeId"])) and
      is_integer(map["changedAtMs"]) and map["changedAtMs"] >= 0 and is_integer(map["osPid"]) and
      map["osPid"] > 0
  end

  defp valid_status?(_), do: false

  defp private_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp atomic_write(path, bytes) do
    temp = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- File.write(temp, bytes, [:exclusive]),
           :ok <- File.chmod(temp, 0o600),
           do: File.rename(temp, path)
    after
      File.rm(temp)
    end
  end
end
