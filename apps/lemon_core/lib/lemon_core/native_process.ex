defmodule LemonCore.NativeProcess do
  @moduledoc """
  Native launch seam with opt-in, eval-only durable ownership tracking.

  Without `:lemon_core, :native_process_ledger`, launches are unchanged. The eval
  harness configures a private ledger before application boot. Every tracked
  launch first syncs an intent, then opens a stdin-gated local process, syncs its
  birth/member witness, and only then releases execution. Failed observation or
  persistence never degrades to an untracked launch. The ledger is independent
  of application startup and of the coding ProcessStore.

  Tracking proves local process-group ownership, not containment of descendants
  which deliberately leave the group, remote work, or adapter-managed sessions.
  """

  use GenServer

  alias LemonCore.{Durable, ProcessGroup}

  @table :lemon_native_processes_dets
  @manifest {:manifest, %{version: 1, kind: :native_processes}}

  @doc false
  def configure!(path) when is_binary(path) do
    # Set the opt-in first: any concurrent launch fails closed until init returns.
    Application.put_env(:lemon_core, :native_process_ledger, path)
    {:ok, _pid} = GenServer.start(__MODULE__, path, name: __MODULE__)
    :ok
  end

  @doc false
  def verify!(path), do: ^path = GenServer.call(__MODULE__, :path)

  @doc false
  def snapshot, do: GenServer.call(__MODULE__, :snapshot, :infinity)

  def open(spec, opts) do
    case Application.get_env(:lemon_core, :native_process_ledger) do
      nil -> Port.open(spec, opts)
      path -> tracked_open(path, spec, opts)
    end
  end

  def cmd(command, args, opts \\ []) do
    case Application.get_env(:lemon_core, :native_process_ledger) do
      nil -> System.cmd(command, args, opts)
      _path -> tracked_cmd(command, args, opts)
    end
  end

  # Whole-workload support is explicit. Call before an operation whose native
  # group is not its whole workload (for example a debugger attachment).
  def unsupported! do
    if path = Application.get_env(:lemon_core, :native_process_ledger) do
      GenServer.call(__MODULE__, {:intent, path, :unsupported}, :infinity)
    end
  end

  def reject_unsupported!(nil), do: :ok

  def reject_unsupported!(id) do
    path = Application.fetch_env!(:lemon_core, :native_process_ledger)
    GenServer.call(__MODULE__, {:rejected, path, id}, :infinity)
  end

  defp tracked_open(path, spec, opts) do
    with {:unix, _} <- :os.type(),
         {:spawn_executable, executable} <- spec,
         executable = to_string(executable),
         true <- Path.type(executable) == :absolute,
         false <- Enum.any?(opts, &unsupported_option?/1) do
      args = Keyword.get(opts, :args, [])

      gated_args = [
        "-c",
        "( IFS= read -r lemon_gate ) && exec \"$@\"",
        "lemon-native",
        executable | args
      ]

      gated_opts = List.keystore(opts, :args, 0, {:args, gated_args})
      id = GenServer.call(__MODULE__, {:intent, path, :local}, :infinity)
      port = Port.open({:spawn_executable, "/bin/sh"}, gated_opts)

      try do
        {:os_pid, pid} = Port.info(port, :os_pid)
        {:ok, identity} = ProcessGroup.capture_workload_group(pid)
        :ok = GenServer.call(__MODULE__, {:captured, path, id, identity}, :infinity)
        true = Port.command(port, "\n")
        port
      catch
        kind, reason ->
          if Port.info(port), do: Port.close(port)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      _ -> raise "native workload cannot be durably observed"
    end
  end

  defp unsupported_option?(:nouse_stdio), do: true
  defp unsupported_option?({:packet, _}), do: true
  defp unsupported_option?({:arg0, _}), do: true
  defp unsupported_option?(_), do: false

  defp tracked_cmd(command, args, opts) do
    executable = System.find_executable(command) || raise ArgumentError, "executable not found"
    {into, opts} = Keyword.pop(opts, :into, "")
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)

    unless timeout == :infinity or (is_integer(timeout) and timeout > 0) do
      raise ArgumentError, "invalid tracked command timeout"
    end

    deadline =
      if timeout == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + timeout

    port_opts =
      Enum.reduce(opts, [:binary, :exit_status, :use_stdio, :hide, {:args, args}], fn
        {:stderr_to_stdout, true}, acc ->
          [:stderr_to_stdout | acc]

        {:stderr_to_stdout, false}, acc ->
          acc

        {:cd, cwd}, acc ->
          [{:cd, cwd} | acc]

        {:env, env}, acc ->
          converted =
            Enum.map(env, fn {key, value} ->
              {to_charlist(key), if(is_nil(value), do: false, else: to_charlist(value))}
            end)

          [{:env, converted} | acc]

        {:parallelism, value}, acc ->
          [{:parallelism, value} | acc]

        option, _acc ->
          raise ArgumentError, "unsupported tracked command option: #{inspect(elem(option, 0))}"
      end)

    {acc, collector} = Collectable.into(into)

    try do
      port = open({:spawn_executable, executable}, port_opts)

      try do
        collect_command(port, acc, collector, deadline)
      after
        if Port.info(port), do: Port.close(port)
      end
    catch
      kind, reason ->
        collector.(acc, :halt)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp collect_command(port, acc, collector, deadline) do
    remaining =
      if deadline == :infinity,
        do: :infinity,
        else: max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        collect_command(port, collector.(acc, {:cont, data}), collector, deadline)

      {^port, {:exit_status, status}} ->
        {collector.(acc, :done), status}
    after
      remaining -> raise "native command timed out"
    end
  end

  @impl true
  def init(path) do
    # Refuse old ledgers before DETS can repair or otherwise mutate them.
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> raise "native process ledger already exists"
    end

    establish_directory!(Path.dirname(Path.expand(path)))

    {:ok, @table} =
      :dets.open_file(@table, file: String.to_charlist(path), type: :set, repair: false)

    try do
      File.chmod!(path, 0o600)
      :ok = :dets.insert(@table, @manifest)
      sync!(path)
      :ok = Durable.sync_directory(Path.dirname(path))
    catch
      kind, reason ->
        :dets.close(@table)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    Process.send_after(self(), :observe, 50)
    {:ok, %{path: path, active: %{}}}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call(:snapshot, _from, state) do
    state = observe(state)

    rows =
      :dets.foldl(
        fn
          @manifest, acc -> acc
          row, acc -> [row | acc]
        end,
        [],
        @table
      )

    {:reply, rows, state}
  end

  def handle_call({:intent, path, backend}, _from, %{path: path} = state) do
    id = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

    record = %{
      backend: backend,
      capacity_held: true,
      termination_confirmed: false,
      workload_identity: nil,
      root_exited: false
    }

    persist(id, record)
    {:reply, id, state}
  end

  def handle_call({:rejected, path, id}, _from, %{path: path} = state) do
    [{^id, %{backend: :unsupported, workload_identity: nil} = record, %{}}] =
      :dets.lookup(@table, id)

    record =
      record
      |> Map.put(:capacity_held, false)
      |> Map.put(:launch_classification, :rejected)

    persist(id, record)
    {:reply, :ok, state}
  end

  def handle_call({:captured, path, id, identity}, _from, %{path: path} = state) do
    true = ProcessGroup.valid_identity?(identity)
    [{^id, %{backend: :local, workload_identity: nil} = record, %{}}] = :dets.lookup(@table, id)
    record = %{record | workload_identity: identity}
    persist(id, record)
    {:reply, :ok, %{state | active: Map.put(state.active, id, record)}}
  end

  @impl true
  def handle_info(:observe, state) do
    state = observe(state)
    Process.send_after(self(), :observe, 50)
    {:noreply, state}
  end

  defp observe(state) do
    statuses =
      state.active
      |> Map.new(fn {id, record} -> {id, record.workload_identity} end)
      |> ProcessGroup.workload_group_statuses()

    active =
      Enum.reduce(state.active, %{}, fn {id, record}, active ->
        case Map.fetch!(statuses, id) do
          :terminated ->
            persist(id, %{record | termination_confirmed: true, capacity_held: false})
            active

          {_status, identity} ->
            updated = %{record | workload_identity: identity}
            if updated != record, do: persist(id, updated)
            Map.put(active, id, updated)
        end
      end)

    %{state | active: active}
  end

  defp persist(id, record) do
    :ok = :dets.insert(@table, {id, record, %{}})
    sync!(to_string(:dets.info(@table, :filename)))
  end

  defp sync!(path) do
    :ok = :dets.sync(@table)
    :ok = Durable.sync_file(path)
  end

  defp establish_directory!(directory) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        parent = Path.dirname(directory)
        establish_directory!(parent)
        File.mkdir!(directory)
        :ok = Durable.sync_directory(parent)

      _ ->
        raise "native process ledger directory unavailable"
    end
  end
end
