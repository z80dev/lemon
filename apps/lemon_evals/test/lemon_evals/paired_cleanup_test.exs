defmodule LemonEvals.PairedCleanupTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Durable, ProcessGroup}
  alias LemonEvals.PairedCleanup

  @native_manifest {:manifest, %{version: 1, kind: :native_processes}}

  @tag :tmp_dir
  test "missing and corrupt ledgers fail closed without creating or replacing evidence", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")
    write_ledger(path <> ".native", [@native_manifest])
    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
    refute File.exists?(path)

    File.write!(path, "not a process ledger")
    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
    assert File.read!(path) == "not a process ledger"

    File.rm!(path)
    write_ledger(path, [])
    File.rm!(path <> ".native")
    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
    refute File.exists?(path <> ".native")

    File.write!(path <> ".native", "not a native ledger")
    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
    assert File.read!(path <> ".native") == "not a native ledger"
  end

  @tag :tmp_dir
  test "native evidence requires its exact supported manifest", %{tmp_dir: dir} do
    path = Path.join(dir, "processes.dets")
    write_ledger(path, [])

    for rows <- [
          [],
          [{:manifest, %{version: 2, kind: :native_processes}}],
          [{:manifest, %{version: 1, kind: :unknown}}],
          [{:manifest, nil}],
          [{:manifest, %{version: 1}}],
          [{:manifest, %{kind: :native_processes}}],
          [{:manifest, %{version: 1, kind: :native_processes, unexpected: true}}]
        ] do
      write_ledger(path <> ".native", rows)
      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
      assert read_ledger(path <> ".native") == rows
    end
  end

  @tag :tmp_dir
  test "unknown and malformed records never hide behind empty scans or terminal flags", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")
    write_ledger(path, [])
    write_ledger(path <> ".native", [@native_manifest])

    invalid_rows = [
      {:unknown, %{version: 1}},
      {"malformed", %{}},
      {"malformed", nil, %{}},
      {nil, %{termination_confirmed: true, capacity_held: false}, %{}},
      {"", %{capacity_held: false, launch_classification: :queued}, %{}},
      {"bad-logs", record(vanished_identity()), nil},
      {"missing-identity", %{backend: :local, root_exited: false}, %{}},
      {"unknown-backend", %{record(vanished_identity()) | backend: :unknown}, %{}}
    ]

    for kind <- [:processes, :native], row <- invalid_rows do
      file = if kind == :native, do: path <> ".native", else: path
      rows = if kind == :native, do: [@native_manifest, row], else: [row]
      write_ledger(file, rows)
      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
      assert Enum.member?(read_ledger(file), row)
      write_ledger(file, if(kind == :native, do: [@native_manifest], else: []))
    end
  end

  @tag :tmp_dir
  test "missing malformed and lost witnesses cannot prove cleanup or release capacity", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")
    write_ledger(path, [])
    write_ledger(path <> ".native", [@native_manifest])

    for kind <- [:processes, :native], identity <- [nil | invalid_identities()] do
      file = if kind == :native, do: path <> ".native", else: path
      row = {"invalid-witness", record(identity), %{stdout: "retained"}}
      write_ledger(file, if(kind == :native, do: [@native_manifest, row], else: [row]))
      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
      assert row in read_ledger(file)
      write_ledger(file, if(kind == :native, do: [@native_manifest], else: []))
    end
  end

  @tag :tmp_dir
  test "empty ledgers and valid vanished witnesses recover without mutating capacity", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")
    write_ledger(path, [])
    write_ledger(path <> ".native", [@native_manifest])
    assert :ok = PairedCleanup.recover(path)

    row = {"vanished", record(vanished_identity()), %{}}
    write_ledger(path, [row])
    write_ledger(path <> ".native", [@native_manifest, row])
    assert :ok = PairedCleanup.recover(path)
    assert read_ledger(path) == [row]
    assert row in read_ledger(path <> ".native")
  end

  @tag :tmp_dir
  test "only a fully declared rejected unsupported native launch proves no admission", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")
    write_ledger(path, [])

    rejected = %{
      backend: :unsupported,
      workload_identity: nil,
      root_exited: false,
      capacity_held: false,
      termination_confirmed: false,
      launch_classification: :rejected
    }

    write_ledger(path <> ".native", [@native_manifest, {"unsupported", rejected, %{}}])
    assert :ok = PairedCleanup.recover(path)

    unverified =
      Enum.map(Map.keys(rejected), &Map.delete(rejected, &1)) ++
        [
          %{rejected | launch_classification: :pending},
          %{rejected | launch_classification: :accepted},
          %{rejected | launch_classification: :queued},
          %{rejected | capacity_held: true},
          %{rejected | termination_confirmed: true},
          %{rejected | root_exited: true},
          %{rejected | workload_identity: vanished_identity()},
          %{rejected | backend: :unknown}
        ]

    for invalid <- unverified do
      row = {"unsupported", invalid, %{}}
      write_ledger(path <> ".native", [@native_manifest, row])
      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
      assert row in read_ledger(path <> ".native")
    end
  end

  @tag :tmp_dir
  test "process terminal confirmation and never-admitted classifications need no witness", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")

    rows =
      [{"terminal", %{termination_confirmed: true, capacity_held: false}, %{}}] ++
        Enum.map([:queued, :rejected, :expired, :canceled], fn classification ->
          {Atom.to_string(classification),
           %{capacity_held: false, launch_classification: classification}, %{}}
        end)

    write_ledger(path, rows)
    write_ledger(path <> ".native", [@native_manifest])
    assert :ok = PairedCleanup.recover(path)
    assert MapSet.new(read_ledger(path)) == MapSet.new(rows)

    contradictory = %{
      capacity_held: false,
      launch_classification: :queued,
      workload_identity: vanished_identity()
    }

    write_ledger(path, [{"contradictory", contradictory, %{}}])
    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
  end

  @tag :tmp_dir
  test "configuration creates private ledgers before boot and verifies actual ownership", %{
    tmp_dir: dir
  } do
    expression = """
    [path] = System.argv()
    Mix.start()
    Mix.env(:test)
    Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test, target: :host))
    System.put_env("LEMON_EVAL_PROCESS_STORE", path)
    nil = Process.whereis(CodingAgent.ProcessStoreServer)
    nil = Process.whereis(LemonCore.NativeProcess)
    :ok = LemonEvals.PairedCleanup.configure!()
    ^path = Application.fetch_env!(:coding_agent, :process_store_path)
    native = path <> ".native"
    ^native = LemonCore.NativeProcess.verify!(native)
    for file <- [path, native] do
      {:ok, stat} = File.stat(file)
      0o600 = Bitwise.band(stat.mode, 0o777)
    end
    {:ok, _} = Application.ensure_all_started(:coding_agent)
    :ok = LemonEvals.PairedCleanup.verify!()
    System.put_env("LEMON_EVAL_PROCESS_STORE", path <> ".wrong")
    try do
      LemonEvals.PairedCleanup.verify!()
      System.halt(1)
    rescue
      MatchError -> :ok
    end
    """

    assert_subprocess(expression, Path.join(dir, "private/processes.dets"))
  end

  @tag :tmp_dir
  test "configuration rejects old and symlinked evidence without replacement", %{tmp_dir: dir} do
    for kind <- [:processes, :native] do
      path = Path.join(dir, "#{kind}.dets")
      file = if kind == :native, do: path <> ".native", else: path
      File.write!(file, "previous attempt")

      expression = """
      [path] = System.argv()
      System.put_env("LEMON_EVAL_PROCESS_STORE", path)
      try do
        LemonEvals.PairedCleanup.configure!()
        System.halt(1)
      rescue
        MatchError -> nil = Process.whereis(LemonCore.NativeProcess)
      end
      """

      assert_subprocess(expression, path)
      assert File.read!(file) == "previous attempt"
      File.rm!(file)
      File.ln_s!("missing-target", file)
      assert_subprocess(expression, path)
      assert {:ok, "missing-target"} = File.read_link(file)
    end
  end

  @tag :tmp_dir
  test "offline recovery boots no runtime and recovers actual groups from both ledgers", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "processes.dets")
    {process_port, process_identity} = gated_group()
    {native_port, native_identity} = gated_group()
    write_ledger(path, [{"process", record(process_identity), %{}}])
    write_ledger(path <> ".native", [@native_manifest, {"native", record(native_identity), %{}}])

    expression = """
    [path] = System.argv()
    before = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    nil = Process.whereis(CodingAgent.ProcessStoreServer)
    nil = Process.whereis(LemonCore.NativeProcess)
    :ok = LemonEvals.PairedCleanup.recover(path)
    ^before = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    nil = Process.whereis(CodingAgent.ProcessStoreServer)
    nil = Process.whereis(LemonCore.NativeProcess)
    """

    assert_subprocess(expression, path)
    assert_receive {^process_port, {:exit_status, _}}, 5_000
    assert_receive {^native_port, {:exit_status, _}}, 5_000
    assert :terminated = ProcessGroup.workload_group_status(process_identity)
    assert :terminated = ProcessGroup.workload_group_status(native_identity)

    assert [{"process", %{capacity_held: true, termination_confirmed: false}, %{}}] =
             read_ledger(path)
  end

  @tag :tmp_dir
  test "real process store rows recover live groups and terminal or never-admitted entries", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "real-processes.dets")
    {port, identity} = gated_group(true)

    expression = """
    [path] = System.argv()
    identity = #{inspect(identity)}
    Application.put_env(:coding_agent, :process_store_path, path)
    {:ok, server} = CodingAgent.ProcessStoreServer.start_link()
    "live" = CodingAgent.ProcessStore.new_process(%{
      id: "live", backend: :local, workload_identity: identity,
      root_exited: false, capacity_held: true, termination_confirmed: false
    })
    :ok = CodingAgent.ProcessStore.append_log("live", "retained output")
    "terminal" = CodingAgent.ProcessStore.new_process(%{
      id: "terminal", capacity_held: false, termination_confirmed: true
    })
    :new = CodingAgent.ProcessStore.register_launch(
      "queued", "owner", "fingerprint",
      System.monotonic_time(:millisecond) + 60_000, self()
    )
    :ok = GenServer.stop(server)
    """

    assert_subprocess(expression, path)
    original = read_ledger(path)
    assert Enum.all?(original, fn {_id, record, logs} -> is_map(record) and is_list(logs) end)
    assert {"live", _, ["retained output"]} = Enum.find(original, &(elem(&1, 0) == "live"))
    write_ledger(path <> ".native", [@native_manifest])

    true = Port.command(port, "\n")
    assert_receive {^port, {:data, "ready"}}, 5_000
    assert :ok = PairedCleanup.recover(path)
    assert_receive {^port, {:exit_status, _}}, 5_000

    assert [{"live", recovered, ["retained output"]}] =
             Enum.filter(read_ledger(path), &(elem(&1, 0) == "live"))

    assert map_size(recovered.workload_identity.members) > map_size(identity.members)
    assert recovered.capacity_held
    refute recovered.termination_confirmed

    for id <- ["terminal", "queued"] do
      assert Enum.find(read_ledger(path), &(elem(&1, 0) == id)) ==
               Enum.find(original, &(elem(&1, 0) == id))
    end

    # Native rows have a distinct map-valued log format.
    write_ledger(path <> ".native", [
      @native_manifest,
      {"native-list-logs", record(vanished_identity()), []}
    ])

    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
  end

  @tag :tmp_dir
  test "an unverified ledger or row does not prevent visiting other proven groups", %{
    tmp_dir: dir
  } do
    for broken <- [:processes, :native, :row] do
      path = Path.join(dir, "#{broken}.dets")
      {port, identity} = gated_group()
      row = {"proven", record(identity), %{}}

      case broken do
        :processes ->
          write_ledger(path <> ".native", [@native_manifest, row])

        :native ->
          write_ledger(path, [row])

        :row ->
          write_ledger(path, [{"unknown", record(nil), %{}}, row])
          write_ledger(path <> ".native", [@native_manifest])
      end

      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
      assert_receive {^port, {:exit_status, _}}, 5_000
      assert :terminated = ProcessGroup.workload_group_status(identity)
    end
  end

  @tag :tmp_dir
  test "stale birth and lost ownership never signal a live unrelated group", %{tmp_dir: dir} do
    path = Path.join(dir, "processes.dets")
    {port, identity} = gated_group()

    stale = %{
      identity
      | root_birth: identity.root_birth <> "-stale",
        members: %{identity.root_pid => identity.root_birth <> "-stale"}
    }

    for kind <- [:processes, :native], witness <- [stale, %{identity | ownership_lost: true}] do
      row = {"unproven", record(witness), %{}}
      write_ledger(path, if(kind == :processes, do: [row], else: []))

      write_ledger(
        path <> ".native",
        if(kind == :native, do: [@native_manifest, row], else: [@native_manifest])
      )

      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
      assert {:alive, _} = ProcessGroup.workload_group_status(identity)
      refute_receive {^port, {:exit_status, _}}, 10
      file = if kind == :native, do: path <> ".native", else: path

      assert [
               {"unproven",
                %{
                  capacity_held: true,
                  termination_confirmed: false,
                  workload_identity: %{ownership_lost: true}
                }, %{}}
             ] =
               Enum.reject(read_ledger(file), &(&1 == @native_manifest))
    end
  end

  @tag :tmp_dir
  test "new members are durably witnessed in the same ledger before signalling", %{tmp_dir: dir} do
    for kind <- [:processes, :native] do
      path = Path.join(dir, "#{kind}.dets")
      {port, identity} = gated_group(true)
      row = {"growing", record(identity), %{stdout: "retained"}}
      write_ledger(path, if(kind == :processes, do: [row], else: []))

      write_ledger(
        path <> ".native",
        if(kind == :native, do: [@native_manifest, row], else: [@native_manifest])
      )

      true = Port.command(port, "\n")
      assert_receive {^port, {:data, "ready"}}, 5_000
      assert {:alive, observed} = ProcessGroup.workload_group_status(identity)
      assert map_size(observed.members) > map_size(identity.members)
      file = if kind == :native, do: path <> ".native", else: path
      parent = self()

      worker =
        spawn(fn ->
          receive do: (:recover ->
                         send(parent, {:recovered, self(), PairedCleanup.recover(path)}))

          receive do: (:finish -> :ok)
        end)

      Code.ensure_loaded!(Durable)
      :erlang.trace_pattern({Durable, :sync_file, 1}, [{:_, [], [{:return_trace}]}], [:local])
      :erlang.trace_pattern({ProcessGroup, :signal_workload_group, 4}, true, [:local])
      :erlang.trace(worker, true, [:call, {:tracer, self()}])

      try do
        send(worker, :recover)
        assert_receive {:recovered, ^worker, :ok}, 10_000
        delivery = :erlang.trace_delivered(worker)
        assert_receive {:trace_delivered, ^worker, ^delivery}
        events = trace_events(worker)
        sync = Enum.find_index(events, &(&1 == {:return_from, {Durable, :sync_file, 1}, :ok}))

        signal =
          Enum.find_index(events, &match?({:call, {ProcessGroup, :signal_workload_group, _}}, &1))

        assert is_integer(sync) and is_integer(signal) and sync < signal
        assert {:call, {Durable, :sync_file, [file]}} in events

        assert {"growing", %{record(identity) | workload_identity: observed},
                %{stdout: "retained"}} in read_ledger(file)

        assert_receive {^port, {:exit_status, _}}, 5_000
      after
        :erlang.trace_pattern({Durable, :sync_file, 1}, false, [:local])
        :erlang.trace_pattern({ProcessGroup, :signal_workload_group, 4}, false, [:local])
        send(worker, :finish)
      end
    end
  end

  @tag :tmp_dir
  test "final revalidation saves a member added after the first observation before kill", %{
    tmp_dir: dir
  } do
    for fail_sync <- [false, true] do
      path = Path.join(dir, "final-#{fail_sync}.dets")
      {port, identity} = gated_group(true)
      assert {:alive, first} = ProcessGroup.workload_group_status(identity)
      write_ledger(path, [{"growing", record(first), %{}}])

      # The first recovery observation contains only the root. Introduce the
      # member in the exact window before the signalling helper revalidates.
      true = Port.command(port, "\n")
      assert_receive {^port, {:data, "ready"}}, 5_000

      persist = fn final ->
        assert map_size(final.members) > map_size(first.members)
        assert {:alive, _} = ProcessGroup.workload_group_status(final)
        refute_receive {^port, {:exit_status, _}}, 0
        write_ledger(path, [{"growing", record(final), %{}}])
        sync_path = if fail_sync, do: path <> ".missing", else: path
        result = Durable.sync_file(sync_path)
        send(self(), {:barrier, final, result})
        result
      end

      result = ProcessGroup.signal_workload_group(first, :sigkill, false, persist)
      assert_receive {:barrier, final, barrier}
      assert [{"growing", %{workload_identity: ^final}, %{}}] = read_ledger(path)

      if fail_sync do
        assert {:error, _} = barrier
        assert {:error, :workload_unobservable, ^final} = result
        assert {:alive, _} = ProcessGroup.workload_group_status(final)
        refute_receive {^port, {:exit_status, _}}, 25
      else
        assert barrier == :ok
        assert {:ok, ^final} = result
        assert_receive {^port, {:exit_status, _}}, 5_000
      end
    end
  end

  @tag :tmp_dir
  @tag :darwin_only
  test "recovery retries an unchanged witness only after a successful durability barrier", %{
    tmp_dir: dir
  } do
    original_path = System.fetch_env!("PATH")

    try do
      for kind <- [:processes, :native] do
        path = Path.join(dir, "retry-#{kind}.dets")
        {port, identity} = gated_group(true)
        row = {"growing", record(identity), %{stdout: "retained"}}
        write_ledger(path, if(kind == :processes, do: [row], else: []))

        write_ledger(
          path <> ".native",
          if(kind == :native, do: [@native_manifest, row], else: [@native_manifest])
        )

        true = Port.command(port, "\n")
        assert_receive {^port, {:data, "ready"}}, 5_000
        assert {:alive, observed} = ProcessGroup.workload_group_status(identity)
        assert map_size(observed.members) > map_size(identity.members)
        file = if kind == :native, do: path <> ".native", else: path

        # Removing Python makes the real Darwin F_FULLFSYNC barrier unavailable,
        # without affecting DETS or the absolute-path process proof/signalling.
        System.put_env("PATH", dir)
        assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)

        saved =
          {"growing", %{record(identity) | workload_identity: observed}, %{stdout: "retained"}}

        assert saved in read_ledger(file)
        assert {:alive, ^observed} = ProcessGroup.workload_group_status(observed)
        refute_receive {^port, {:exit_status, _}}, 25

        # The first attempt inserted the witness before failing its barrier.
        # Reopening DETS and seeing identical membership is not a durable sync.
        assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
        assert saved in read_ledger(file)
        assert {:alive, ^observed} = ProcessGroup.workload_group_status(observed)
        refute_receive {^port, {:exit_status, _}}, 25

        System.put_env("PATH", original_path)
        assert :ok = PairedCleanup.recover(path)
        assert_receive {^port, {:exit_status, _}}, 5_000
        assert :terminated = ProcessGroup.workload_group_status(observed)
        assert saved in read_ledger(file)
      end
    after
      System.put_env("PATH", original_path)
    end
  end

  @tag :tmp_dir
  test "recovery refuses live-open or symlinked ledgers", %{tmp_dir: dir} do
    path = Path.join(dir, "processes.dets")
    write_ledger(path, [])
    write_ledger(path <> ".native", [@native_manifest])
    {:ok, table} = :dets.open_file(:paired_cleanup_open_fixture, file: String.to_charlist(path))

    try do
      assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
    after
      :ok = :dets.close(table)
    end

    File.rename!(path, path <> ".original")
    File.ln_s!(path <> ".original", path)
    assert {:error, :cleanup_unverified} = PairedCleanup.recover(path)
    assert File.regular?(path <> ".original")
  end

  defp trace_events(worker, acc \\ []) do
    receive do
      {:trace, ^worker, :call, call} ->
        trace_events(worker, [{:call, call} | acc])

      {:trace, ^worker, :return_from, call, result} ->
        trace_events(worker, [{:return_from, call, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_subprocess(expression, path) do
    home = Path.join(Path.dirname(path), "subprocess-home")
    File.mkdir_p!(home)

    # Reuse compiled code, not Mix's build lock held by the parent test run.
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    {output, status} =
      System.cmd(
        System.find_executable("elixir") || raise("elixir is required"),
        code_paths ++ ["-e", expression, "--", path],
        cd: Path.expand("../../../..", __DIR__),
        env: [
          {"MIX_ENV", "test"},
          {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
          {"HOME", home},
          {"LEMON_AGENT_DIR", Path.join(home, "agent")},
          {"LEMON_STORE_PATH", Path.join(home, "store")}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp gated_group(children \\ false) do
    script =
      if children,
        do: "IFS= read -r start; /bin/sleep 60 & printf ready; IFS= read -r finish",
        else: "IFS= read -r finish"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", script]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert {:ok, identity} = ProcessGroup.capture_workload_group(pid)

    on_exit(fn ->
      ProcessGroup.signal_workload_group(identity, :sigkill)
      if Port.info(port), do: Port.close(port)
    end)

    {port, identity}
  end

  defp write_ledger(path, rows) do
    {:ok, table} =
      :dets.open_file(:paired_cleanup_fixture, file: String.to_charlist(path), type: :set)

    try do
      :ok = :dets.delete_all_objects(table)
      :ok = :dets.insert(table, rows)
      :ok = :dets.sync(table)
    after
      :ok = :dets.close(table)
    end
  end

  defp read_ledger(path) do
    {:ok, table} =
      :dets.open_file(:paired_cleanup_fixture, file: String.to_charlist(path), type: :set)

    try do
      :dets.foldl(fn row, rows -> [row | rows] end, [], table)
    after
      :ok = :dets.close(table)
    end
  end

  defp record(identity) do
    %{
      backend: :local,
      workload_identity: identity,
      root_exited: false,
      capacity_held: true,
      termination_confirmed: false
    }
  end

  defp vanished_identity do
    %{
      pgid: 999_999_999,
      root_pid: 999_999_999,
      root_birth: "captured birth",
      members: %{999_999_999 => "captured birth"},
      ownership_lost: false
    }
  end

  defp invalid_identities do
    captured = vanished_identity()

    [
      %{},
      %{pgid: nil, root_pid: nil},
      %{captured | pgid: 0, root_pid: 0},
      %{captured | root_pid: 999_999_998},
      %{captured | root_birth: ""},
      %{captured | members: %{}},
      %{captured | members: %{999_999_999 => "different birth"}},
      %{captured | members: %{999_999_999 => "captured birth", nil => "member birth"}},
      Map.delete(captured, :ownership_lost),
      %{captured | ownership_lost: true}
    ]
  end
end
