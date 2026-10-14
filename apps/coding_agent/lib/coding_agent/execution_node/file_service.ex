defmodule CodingAgent.ExecutionNode.FileService do
  @moduledoc """
  Worker-local serialized filesystem owner. The Python helper pins root directory
  descriptors, performs NOFOLLOW descriptor-relative operations and owns ephemeral
  deletion previews. Worker writes (including aliases of the same path) are
  serialized through this service, so revision comparison and mutation cannot be
  interleaved by another worker request. This is not a sandbox for local processes.
  """
  use GenServer

  @errors ~w(invalid_request invalid_path path_not_allowed invalid_allowed_roots
    symlink_loop not_found not_directory not_regular_file content_too_large
    invalid_base64 permission_denied directory_not_empty already_exists
    filesystem_failed revision_conflict invalid_confirmation_token
    confirmation_expired confirmation_required stale_preview preview_too_large
    filesystem_outcome_unknown atomic_move_unavailable filesystem_busy)a
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)


  @doc false
  def path_policy(opts) do
    home = Keyword.get(opts, :home) || System.user_home!()
    %{"cwd" => Keyword.get(opts, :default_cwd) || home,
      "roots" => Keyword.get(opts, :allowed_roots, [home])}
  end

  def handle(method, args, opts) do
    policy = path_policy(opts)
    with {:ok, pid} <- ensure_started() do
      deadline = System.monotonic_time(:millisecond) + 25_000
      try do
        GenServer.call(pid, {:request, method, args, policy, deadline}, 30_000)
      catch
        :exit, _ -> {:error, :filesystem_outcome_unknown}
      end
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :host_io_unavailable}
      pid -> {:ok, pid}
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  defp open_port do
    case System.find_executable("python3") do
      nil -> {:error, :host_io_unavailable}
      python ->
        helper = Path.join(to_string(:code.priv_dir(:coding_agent)), "node_fs.py")
        port = Port.open({:spawn_executable, python}, [
          :binary, :exit_status, {:packet, 4}, {:args, [helper]}
        ])
        {:ok, port}
    end
  end

  @impl true
  def handle_call(request, from, nil) do
    case open_port() do
      {:ok, port} -> handle_call(request, from, port)
      {:error, reason} -> {:reply, {:error, reason}, nil}
    end
  end

  def handle_call({:request, method, args, policy, deadline}, _from, port) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0 do
      {:reply, {:error, :host_io_unavailable}, port}
    else
      request = Jason.encode!(%{"method" => method, "args" => args, "policy" => policy})
      if Port.command(port, request, [:nosuspend]) do
        receive do
          {^port, {:data, data}} -> {:reply, decode(data), port}
          {^port, {:exit_status, _}} ->
            {:stop, :normal, {:error, :filesystem_outcome_unknown}, port}
          {:EXIT, ^port, _} ->
            {:stop, :normal, {:error, :filesystem_outcome_unknown}, port}
        after
          remaining ->
            {:stop, :normal, {:error, :filesystem_outcome_unknown}, port}
        end
      else
        {:reply, {:error, :host_io_unavailable}, port}
      end
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, port), do: {:stop, :normal, port}
  def handle_info({:EXIT, port, _}, port), do: {:stop, :normal, port}
  def handle_info(_, port), do: {:noreply, port}

  @impl true
  def terminate(_, nil), do: :ok
  def terminate(_, port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp decode(data) do
    case Jason.decode(data) do
      {:ok, %{"ok" => result}} when is_map(result) -> {:ok, mime(result)}
      {:ok, %{"error" => name}} ->
        {:error, Enum.find(@errors, :filesystem_failed, &(Atom.to_string(&1) == name))}
      _ -> {:error, :filesystem_failed}
    end
  end

  defp mime(%{"stat" => stat} = result), do: Map.put(result, "stat", mime(stat))
  defp mime(%{"entries" => entries} = result), do: Map.put(result, "entries", Enum.map(entries, &mime/1))
  defp mime(%{"path" => path} = result) do
    if Map.has_key?(result, "type") or Map.has_key?(result, "dataBase64"),
      do: Map.put(result, "mime", MIME.from_path(path)),
      else: result
  end
  defp mime(result), do: result
end
