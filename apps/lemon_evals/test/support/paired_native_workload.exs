# Invoked only by test_paired_native_cleanup.py in its own disposable VM.
# No provider/runtime listener is started. Commands are quiet, FIFO-held and
# admitted through production execution paths and their durable stores.
alias CodingAgent.{ProcessManager, ProcessStore}

# Load configuration without invoking Mix tasks, compilation, or application boot.
Mix.start()
Mix.env(:test)
Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test, target: :host))

mode = System.fetch_env!("LEMON_EVAL_CLEANUP_MODE")
File.cd!(System.fetch_env!("LEMON_AGENT_PROFILES_CWD"))
LemonEvals.PairedCleanup.configure!()
root = System.fetch_env!("LEMON_EVAL_CLEANUP_ROOT")
parent = self()
ready = Path.join(root, "ready")
hold = Path.join(root, "hold")
quote = fn path -> "'" <> String.replace(path, "'", "'\"'\"'") <> "'" end
pid_path = Path.join(root, "workload.pid")

spawn(fn ->
  {"ready", 0} = System.cmd("cat", [ready])
  send(parent, :ready)
end)

blocked = "trap '' TERM; printf ready > #{quote.(ready)}; read -r release < #{quote.(hold)}"

if mode == "validation" do
  marker = Path.join(root, "invalid-launch-executed")
  args = ["-c", "printf admitted > \"$1\"", "validation", marker]

  rejected = [
    fn -> LemonCore.NativeProcess.open({:spawn_executable, "sh"}, [:binary, args: args]) end,
    fn ->
      LemonCore.NativeProcess.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :nouse_stdio,
        args: args
      ])
    end,
    fn ->
      LemonCore.NativeProcess.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        packet: 4,
        args: args
      ])
    end,
    fn ->
      LemonCore.NativeProcess.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        arg0: "invalid",
        args: args
      ])
    end,
    fn -> LemonCore.NativeProcess.cmd("/bin/sh", args, unsupported_option: true) end,
    fn -> LemonCore.NativeProcess.cmd("/bin/sh", args, into: 42) end
  ]

  for launch <- rejected do
    {:rejected, _error} =
      try do
        {:accepted, launch.()}
      rescue
        error -> {:rejected, error}
      end
  end

  [] = LemonCore.NativeProcess.snapshot()
  false = File.exists?(marker)

  {"out:owned\nerr\n", 7} =
    LemonCore.NativeProcess.cmd(
      "/bin/sh",
      [
        "-c",
        "test \"$PWD\" -ef \"$EXPECTED\" || exit 9; printf 'out:%s\\n' \"$OWNED\"; printf 'err\\n' >&2; exit 7"
      ],
      cd: root,
      env: [{"EXPECTED", root}, {"OWNED", "owned"}],
      stderr_to_stdout: true
    )

  before_source = length(LemonCore.NativeProcess.snapshot())

  {:ok, %{output: "owned-source", byte_count: 12}} =
    LemonCore.Secrets.SourceRunner.run(
      ["/bin/sh", "-c", "printf owned-source"],
      timeout_ms: 5_000,
      max_output_bytes: 64
    )

  true = length(LemonCore.NativeProcess.snapshot()) == before_source + 1
end

preboot_workload =
  if mode in ["preboot", "validation"] do
    nil = Process.whereis(CodingAgent.ProcessStoreServer)

    port =
      LemonCore.NativeProcess.open(
        {:spawn_executable, System.find_executable("sh") || raise("sh is required")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-c", "printf '%s' \"$$\" > #{quote.(pid_path)}; " <> blocked]}
        ]
      )

    receive do
      :ready -> :ok
      {^port, {:exit_status, status}} -> raise "preboot shell exited: #{status}"
    after
      5_000 -> raise "preboot workload ready barrier failed"
    end

    pid = pid_path |> File.read!() |> String.to_integer()
    {:os_pid, ^pid} = Port.info(port, :os_pid)

    [{id, %{backend: :local, root_exited: false} = record, logs}] =
      Enum.filter(LemonCore.NativeProcess.snapshot(), fn {_id, record, _logs} ->
        is_map(record.workload_identity) and record.workload_identity.root_pid == pid
      end)

    nil = Process.whereis(CodingAgent.ProcessStoreServer)
    {id, record, logs}
  end

{:ok, _} = Application.ensure_all_started(:coding_agent)
LemonEvals.PairedCleanup.verify!()

{id, record, _logs} =
  case mode do
    mode when mode in ["preboot", "validation"] ->
      preboot_workload

    "foreground" ->
      tool = CodingAgent.Tools.Bash.tool(root)
      command = "printf '%s' \"$$\" > #{quote.(pid_path)}; " <> blocked

      spawn_link(fn ->
        result = tool.execute.("paired-foreground", %{"command" => command}, nil, nil)
        send(parent, {:unexpected_completion, result})
      end)

      receive do
        :ready -> :ok
        {:unexpected_completion, result} -> raise "foreground command ended: #{inspect(result)}"
      after
        5_000 -> raise "foreground workload ready barrier failed"
      end

      pid = pid_path |> File.read!() |> String.to_integer()

      # Ordinary foreground tools now use ProcessManager rather than the
      # NativeProcess ledger; keep the production tool path, not its old backend.
      [{id, %{backend: :local, root_exited: false}}] =
        Enum.filter(ProcessStore.list(), fn {_id, record} ->
          is_map(record.workload_identity) and record.workload_identity.root_pid == pid
        end)

      {:ok, record, logs} = ProcessStore.get(id)
      {id, record, logs}

    "kernel" ->
      {:ok, slot} =
        CodingAgent.Eval.Kernel.start_link(
          key: {"paired-cleanup-fixture", "py"},
          language: "py",
          cwd: root,
          runtime: System.find_executable("python3") || raise("python3 is required"),
          owner_pid: parent
        )

      {:ok, %{ref: ref}} =
        CodingAgent.Eval.Kernel.run(slot, "total = sum(i * i for i in range(10))\ntotal")

      receive do
        {:lemon_eval, ^ref, {:result, %{"status" => "ok", "display" => "285"}}} -> :ok
        {:lemon_eval, ^ref, result} -> raise "kernel calculation failed: #{inspect(result)}"
      after
        5_000 -> raise "kernel calculation result timed out"
      end

      {:ok, %{ref: held_ref}} =
        CodingAgent.Eval.Kernel.run(slot, """
        import json, os, signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open("kernel-result.json", "w") as result:
            json.dump({"total": total, "pid": os.getpid()}, result)
        with open("ready", "w") as ready:
            ready.write("ready")
        with open("hold") as hold:
            hold.readline()
        """)

      receive do
        :ready -> :ok
        {:lemon_eval, ^held_ref, result} -> raise "held kernel ended: #{inspect(result)}"
      after
        5_000 -> raise "kernel workload ready barrier failed"
      end

      pid = CodingAgent.Eval.Kernel.os_pid(slot)

      [{id, %{backend: :local, root_exited: false} = record, logs}] =
        Enum.filter(LemonCore.NativeProcess.snapshot(), fn {_id, record, _logs} ->
          is_map(record.workload_identity) and record.workload_identity.root_pid == pid
        end)

      {id, record, logs}

    "browser" ->
      {:ok, _} = Application.ensure_all_started(:lemon_browser)
      driver = Path.join(root, "held-browser-driver.cjs")

      File.write!(driver, """
      const fs = require("node:fs");
      process.on("SIGTERM", () => {});
      fs.writeFileSync(#{Jason.encode!(pid_path)}, String(process.pid));
      fs.writeFileSync(#{Jason.encode!(ready)}, "ready");
      const held = fs.openSync(#{Jason.encode!(hold)}, "r");
      fs.readSync(held, Buffer.alloc(1), 0, 1, null);
      """)

      {:ok, server} = LemonBrowser.LocalServer.start_link(name: nil, driver_path: driver)

      spawn_link(fn ->
        result = LemonBrowser.LocalServer.request(server, "browser.navigate", %{}, 120_000)
        send(parent, {:unexpected_completion, result})
      end)

      receive do
        :ready -> :ok
        {:unexpected_completion, result} -> raise "browser driver ended: #{inspect(result)}"
      after
        5_000 -> raise "browser workload ready barrier failed"
      end

      pid = pid_path |> File.read!() |> String.to_integer()
      rows = LemonCore.NativeProcess.snapshot()
      true = Enum.any?(rows, fn {_id, record, _logs} -> record.backend == :unsupported end)

      [{id, record, logs}] =
        Enum.filter(rows, fn {_id, record, _logs} ->
          is_map(record.workload_identity) and record.workload_identity.root_pid == pid
        end)

      {id, record, logs}

    _ ->
      command =
        if mode == "descendant",
          do: "trap 'exit 0' TERM; (#{blocked}) </dev/null >/dev/null 2>&1 & read -r release",
          else: blocked

      {:ok, id} =
        ProcessManager.exec(
          command: command,
          owner: "paired-cleanup-fixture",
          owner_pid: parent,
          admission_wait_ms: 5_000,
          on_root_exit: fn id -> send(parent, {:root_exited, id}) end
        )

      receive do
        :ready -> :ok
      after
        5_000 -> raise "native workload ready barrier failed"
      end

      if mode == "descendant" do
        :ok = ProcessManager.write(id, "release\n")

        receive do
          {:root_exited, ^id} -> :ok
        after
          5_000 -> raise "native root exit barrier failed"
        end
      end

      {:ok, record, logs} = ProcessStore.get(id)
      identity = record.workload_identity

      # Explicit durable witness fault injection; the real OS process remains alive.
      case mode do
        "missing" ->
          ProcessStore.update_workload_identity(id, nil, false)

        "lost" ->
          ProcessStore.update_workload_identity(id, %{identity | ownership_lost: true}, false)

        "stale" ->
          ProcessStore.update_workload_identity(
            id,
            %{identity | root_birth: "not this process"},
            false
          )

        "unsupported" ->
          ProcessStore.insert_record(id, Map.put(record, :backend, :local_pty), logs)

        _ ->
          :ok
      end

      :ok = :dets.sync(:coding_agent_processes_dets)
      {id, record, logs}
  end

identity = record.workload_identity

durable_record =
  if mode in ["missing", "lost", "stale", "unsupported"] do
    {:ok, stored, _logs} = ProcessStore.get(id)
    Map.take(stored, [:backend, :workload_identity, :capacity_held, :termination_confirmed])
  end

# Let the native shell establish its own TERM traps before making this VM
# ignore TERM for the forced-shutdown cases.
if mode != "graceful", do: :os.set_signal(:sigterm, :ignore)

File.write!(
  Path.join(root, "native.json.tmp"),
  Jason.encode!(%{
    id: id,
    ledger:
      if(mode in ["preboot", "validation", "kernel", "browser"],
        do: "native",
        else: "process_manager"
      ),
    tracked_before_boot: mode in ["preboot", "validation"],
    identity: identity,
    durable_record: durable_record,
    root_exited: Map.get(record, :root_exited, false)
  })
)

File.rename!(Path.join(root, "native.json.tmp"), Path.join(root, "native.json"))
Process.sleep(:infinity)
