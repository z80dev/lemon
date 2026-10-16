defmodule LemonCore.NativeProcessTest do
  use ExUnit.Case, async: false

  alias LemonCore.{NativeProcess, ProcessGroup}

  @table :lemon_native_processes_dets

  setup do
    original = Application.fetch_env(:lemon_core, :native_process_ledger)
    Application.delete_env(:lemon_core, :native_process_ledger)

    directory =
      Path.join(System.tmp_dir!(), "lemon-native-process-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    on_exit(fn ->
      if pid = Process.whereis(NativeProcess) do
        for {_id, record, %{}} <- NativeProcess.snapshot() do
          if ProcessGroup.valid_identity?(record.workload_identity) do
            ProcessGroup.signal_workload_group(record.workload_identity, :sigkill)
          end
        end

        GenServer.stop(pid)
      end

      if :dets.info(@table) != :undefined, do: :dets.close(@table)

      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end

      File.rm_rf!(directory)
    end)

    %{directory: directory, ledger: Path.join(directory, "processes.dets")}
  end

  test "unconfigured commands preserve System.cmd output, status, arguments and environment" do
    assert {"a b:value", 7} =
             NativeProcess.cmd(
               "/bin/sh",
               ["-c", "printf '%s:%s' \"$1\" \"$NATIVE_TEST\"; exit 7", "test", "a b"],
               env: [{"NATIVE_TEST", "value"}]
             )

    assert Process.whereis(NativeProcess) == nil
  end

  test "unconfigured ports retain direct executable launch behavior" do
    port =
      NativeProcess.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "printf direct; exit 3"]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert_receive {^port, {:data, "direct"}}, 5_000
    assert_receive {^port, {:exit_status, 3}}, 5_000
  end

  test "durable intent and birth witness precede release of the gated workload", context do
    assert :ok = NativeProcess.configure!(context.ledger)
    assert context.ledger == NativeProcess.verify!(context.ledger)
    marker = Path.join(context.directory, "started")
    test = self()
    capture_gate = :atomics.new(1, [])

    debug = fn state, event, _extra ->
      case event do
        {:in, {:"$gen_call", _from, {:captured, _path, id, identity}}} ->
          :atomics.put(capture_gate, 1, 1)
          send(test, {:capture_boundary, self(), id, identity})
          receive do: (:release_capture -> :ok)
          :atomics.put(capture_gate, 1, 2)

        _ ->
          :ok
      end

      state
    end

    :ok = :sys.install(NativeProcess, {debug, nil})

    worker =
      spawn(fn ->
        port =
          NativeProcess.open(
            {:spawn_executable, "/bin/sh"},
            [
              :binary,
              :exit_status,
              args: ["-c", "printf started > \"$1\"; IFS= read -r lemon_gate", "test", marker]
            ]
          )

        send(test, {:opened, self(), port})
        receive do: (:finish -> Port.close(port))
      end)

    on_exit(fn ->
      if :atomics.compare_exchange(capture_gate, 1, 1, 2) == :ok do
        if server = Process.whereis(NativeProcess), do: send(server, :release_capture)
      end

      if Process.whereis(NativeProcess), do: :sys.remove(NativeProcess, debug)

      if Process.alive?(worker) do
        try do
          :erlang.resume_process(worker)
        catch
          :error, :badarg -> :ok
        end

        Process.exit(worker, :kill)
      end
    end)

    assert_receive {:capture_boundary, server, id, identity}, 5_000
    assert ProcessGroup.valid_identity?(identity)

    assert [
             {^id, %{workload_identity: nil, capacity_held: true, termination_confirmed: false},
              %{}}
           ] =
             persisted_rows(context, id, "intent")

    refute File.exists?(marker)

    true = :erlang.suspend_process(worker)
    :atomics.put(capture_gate, 1, 2)
    send(server, :release_capture)
    assert :ok = :sys.remove(NativeProcess, debug)

    assert [{^id, %{workload_identity: witness, capacity_held: true}, %{}}] =
             persisted_rows(context, id, "witness")

    assert ProcessGroup.valid_identity?(witness)
    assert Map.drop(witness, [:members]) == Map.drop(identity, [:members])
    assert Map.take(witness.members, Map.keys(identity.members)) == identity.members

    refute File.exists?(marker)
    true = :erlang.resume_process(worker)
    assert_receive {:opened, ^worker, port}, 5_000
    eventually(fn -> File.exists?(marker) end)
    assert File.read!(marker) == "started"
    assert true = Port.command(port, "\n")
    send(worker, :finish)

    eventually(fn ->
      case NativeProcess.snapshot() do
        [{^id, %{termination_confirmed: true, capacity_held: false}, %{}}] -> true
        _ -> false
      end
    end)
  end

  test "configured but unavailable ledger never runs the command", context do
    Application.put_env(:lemon_core, :native_process_ledger, context.ledger)
    marker = Path.join(context.directory, "must-not-start")
    assert catch_exit(NativeProcess.cmd("/bin/sh", ["-c", "printf bad > \"$1\"", "test", marker]))
    refute File.exists?(marker)
  end

  test "tracked commands collect real output and release capacity after exit", context do
    NativeProcess.configure!(context.ledger)

    assert {"tracked:value", 4} =
             NativeProcess.cmd("/bin/sh", ["-c", "printf 'tracked:%s' \"$NATIVE_TEST\"; exit 4"],
               env: [{"NATIVE_TEST", "value"}]
             )

    eventually(fn ->
      case NativeProcess.snapshot() do
        [{_id, %{backend: :local, capacity_held: false, termination_confirmed: true}, %{}}] ->
          true

        _ ->
          false
      end
    end)
  end

  test "mismatched ledger fails closed before launch", context do
    NativeProcess.configure!(context.ledger)
    Application.put_env(:lemon_core, :native_process_ledger, context.ledger <> ".other")
    marker = Path.join(context.directory, "must-not-start")
    assert catch_exit(NativeProcess.cmd("/bin/sh", ["-c", "printf bad > \"$1\"", "test", marker]))
    refute File.exists?(marker)
  end

  test "unsupported records stay occupied until explicitly rejected", context do
    assert nil == NativeProcess.unsupported!()
    assert :ok == NativeProcess.reject_unsupported!(nil)
    NativeProcess.configure!(context.ledger)
    id = NativeProcess.unsupported!()

    assert [
             {^id,
              %{
                backend: :unsupported,
                workload_identity: nil,
                capacity_held: true,
                termination_confirmed: false
              }, %{}}
           ] = NativeProcess.snapshot()

    send(Process.whereis(NativeProcess), :observe)

    assert [{^id, %{capacity_held: true, termination_confirmed: false}, %{}}] =
             NativeProcess.snapshot()

    assert :ok = NativeProcess.reject_unsupported!(id)

    assert [
             {^id,
              %{
                capacity_held: false,
                termination_confirmed: false,
                launch_classification: :rejected
              }, %{}}
           ] = NativeProcess.snapshot()
  end

  test "POSIX shell gate preserves argv under dash when available" do
    shell = System.find_executable("dash") || "/bin/sh"

    assert {"literal argument", 0} =
             System.cmd(shell, [
               "-c",
               "printf '\\n' | ( ( IFS= read -r lemon_gate ) && exec \"$@\" )",
               "lemon-native",
               "/usr/bin/printf",
               "%s",
               "literal argument"
             ])
  end

  test "configuration durably establishes nested directories", context do
    ledger = Path.join([context.directory, "new", "nested", "processes.dets"])
    assert :ok = NativeProcess.configure!(ledger)
    assert File.regular?(ledger)
    assert :ok = LemonCore.Durable.sync_file(ledger)
  end

  test "existing ledgers are refused without repair or modification", context do
    File.write!(context.ledger, "not a DETS file")
    assert catch_error(NativeProcess.configure!(context.ledger))
    assert File.read!(context.ledger) == "not a DETS file"
    assert :dets.info(@table) == :undefined
  end

  test "directory barrier failure prevents successful configuration", context do
    original_path = System.fetch_env!("PATH")
    System.put_env("PATH", context.directory)

    try do
      assert catch_error(NativeProcess.configure!(context.ledger))
      refute Process.whereis(NativeProcess)
      assert :dets.info(@table) == :undefined
    after
      System.put_env("PATH", original_path)
    end
  end

  for boundary <- [:intent, :captured] do
    test "#{boundary} file barrier failure never releases the workload", context do
      NativeProcess.configure!(context.ledger)
      marker = Path.join(context.directory, "must-not-start")
      boundary = unquote(boundary)
      ledger = context.ledger

      debug = fn state, event, _extra ->
        case event do
          {:in, {:"$gen_call", _from, request}}
          when is_tuple(request) and elem(request, 0) == boundary ->
            File.rename!(ledger, ledger <> ".removed")

          _ ->
            :ok
        end

        state
      end

      :ok = :sys.install(NativeProcess, {debug, nil})

      assert catch_exit(
               NativeProcess.cmd("/bin/sh", ["-c", "printf bad > \"$1\"", "test", marker])
             )

      refute File.exists?(marker)
      refute Process.whereis(NativeProcess)
    end
  end

  defp persisted_rows(context, id, suffix) do
    copy = Path.join(context.directory, suffix <> ".dets")
    File.cp!(context.ledger, copy)

    {:ok, table} =
      :dets.open_file(:native_process_test_copy, file: String.to_charlist(copy), repair: false)

    try do
      :dets.lookup(table, id)
    after
      :dets.close(table)
    end
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      eventually(predicate, attempts - 1)
    end
  end
end
