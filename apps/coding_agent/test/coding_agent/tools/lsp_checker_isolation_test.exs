defmodule CodingAgent.Tools.LspCheckerIsolationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.{LspDiagnostics, LspFormatter}
  alias LemonAgent.AbortSignal

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_path = System.get_env("PATH")
    project = Path.join(tmp_dir, "project")
    operator_bin = Path.join(tmp_dir, "operator_bin")
    File.mkdir_p!(project)
    File.mkdir_p!(operator_bin)
    pid_file = Path.join(tmp_dir, "pids")

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if File.exists?(pid_file) do
        for pid <- String.split(File.read!(pid_file)) do
          System.cmd("/bin/kill", ["-KILL", pid], stderr_to_stdout: true)
        end
      end
    end)

    %{
      project: project,
      operator_bin: operator_bin,
      pid_file: pid_file,
      previous_path: previous_path
    }
  end

  test "aborting diagnostics kills the checker, which runs under ProcessManager", ctx do
    sleeping_executable(ctx.operator_bin, "go", ctx.pid_file)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        LspDiagnostics.diagnose_file(path, ctx.project,
          diagnostics_timeout_ms: 60_000,
          signal: signal
        )
      end)

    pids = await_pids(ctx.pid_file, 100)
    assert managed?(Path.join(ctx.operator_bin, "go"))
    AbortSignal.abort(signal)

    assert {:ok, {:ok, result}} = Task.yield(task, 5_000)
    assert result.status == :failed or result[:command_exit_status] != 0
    Enum.each(pids, &assert_process_gone(&1, 40))
  end

  test "aborting a formatter kills it", ctx do
    sleeping_executable(ctx.operator_bin, "black", ctx.pid_file)
    path = Path.join(ctx.project, "a.py")
    File.write!(path, "x = 1\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        LspFormatter.format_file(path, cwd: ctx.project, timeout_ms: 60_000, signal: signal)
      end)

    pids = await_pids(ctx.pid_file, 100)
    AbortSignal.abort(signal)

    assert {:ok, {:error, _}} = Task.yield(task, 5_000)
    Enum.each(pids, &assert_process_gone(&1, 40))
  end

  test "TypeScript prefers the operator tsc over a repo node_modules/.bin/tsc", ctx do
    repo_marker = Path.join(ctx.project, "repo-tsc-ran")
    operator_marker = Path.join(ctx.operator_bin, "operator-tsc-ran")
    local_bin = Path.join([ctx.project, "node_modules", ".bin"])
    File.mkdir_p!(local_bin)
    marker_executable(local_bin, "tsc", repo_marker)
    marker_executable(ctx.operator_bin, "tsc", operator_marker)
    File.write!(Path.join(ctx.project, "tsconfig.json"), "{}")
    path = Path.join(ctx.project, "a.ts")
    File.write!(path, "export const x = 1\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)

    assert {:ok, _} = LspDiagnostics.diagnose_file(path, ctx.project)
    refute File.exists?(repo_marker)
    assert File.exists?(operator_marker)

    File.rm!(operator_marker)
    assert {:ok, _} = LspDiagnostics.diagnose_file(path, ctx.project, repo_local_tools: true)
    assert File.exists?(repo_marker)
  end

  test "without an operator tsc, the repo tsc is not run", ctx do
    repo_marker = Path.join(ctx.project, "repo-tsc-ran")
    local_bin = Path.join([ctx.project, "node_modules", ".bin"])
    File.mkdir_p!(local_bin)
    marker_executable(local_bin, "tsc", repo_marker)
    # npx would resolve the repo-local binary too.
    marker_executable(ctx.operator_bin, "npx", repo_marker)
    File.write!(Path.join(ctx.project, "tsconfig.json"), "{}")
    path = Path.join(ctx.project, "a.ts")
    File.write!(path, "export const x = 1\n")
    System.put_env("PATH", ctx.operator_bin <> ":/usr/bin:/bin")

    assert {:ok, result} = LspDiagnostics.diagnose_file(path, ctx.project)
    assert result.status == :skipped
    refute File.exists?(repo_marker)
  end

  test "PATH entries inside the workspace never supply checkers or formatters", ctx do
    repo_marker = Path.join(ctx.project, "repo-tool-ran")
    repo_bin = Path.join(ctx.project, "bin")
    File.mkdir_p!(repo_bin)
    marker_executable(repo_bin, "go", repo_marker)
    marker_executable(repo_bin, "black", repo_marker)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    go = Path.join(ctx.project, "main.go")
    File.write!(go, "package main\n")
    py = Path.join(ctx.project, "a.py")
    File.write!(py, "x = 1\n")
    System.put_env("PATH", repo_bin <> ":/usr/bin:/bin")

    assert {:ok, %{status: :skipped}} = LspDiagnostics.diagnose_file(go, ctx.project)

    assert {:error, "refused repo-local executable: black" <> _} =
             LspFormatter.format_file(py, cwd: ctx.project)

    assert {:ok, _} = LspDiagnostics.diagnose_file(go, ctx.project, repo_local_tools: true)
    assert File.exists?(repo_marker)
  end

  describe "symlink aliases of workspace binaries are refused" do
    setup ctx do
      repo_marker = Path.join(ctx.project, "repo-tool-ran")
      repo_bin = Path.join(ctx.project, "bin")
      File.mkdir_p!(repo_bin)
      marker_executable(repo_bin, "go", repo_marker)
      File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
      File.write!(Path.join(ctx.project, "main.go"), "package main\n")
      %{repo_marker: repo_marker, repo_bin: repo_bin}
    end

    test "an operator PATH entry that symlinks to a repo executable", ctx do
      File.ln_s!(Path.join(ctx.repo_bin, "go"), Path.join(ctx.operator_bin, "go"))
      System.put_env("PATH", ctx.operator_bin <> ":/usr/bin:/bin")
      assert_refused(ctx, ctx.project)
    end

    test "a PATH directory that is a symlink into the repo", ctx do
      link_dir = Path.join(ctx.tmp_dir, "linked_bin")
      File.ln_s!(ctx.repo_bin, link_dir)
      System.put_env("PATH", link_dir <> ":/usr/bin:/bin")
      assert_refused(ctx, ctx.project)
    end

    test "a workspace opened through an alias path", ctx do
      alias_root = Path.join(ctx.tmp_dir, "alias")
      File.ln_s!(ctx.project, alias_root)
      System.put_env("PATH", ctx.repo_bin <> ":/usr/bin:/bin")
      assert_refused(ctx, alias_root)
    end
  end

  test "a checker that forks a detached child and exits early leaves nothing behind", ctx do
    executable = Path.join(ctx.operator_bin, "go")

    File.write!(executable, """
    #!/bin/sh
    /bin/sleep 60 </dev/null >/dev/null 2>&1 &
    printf '%s\\n' "$!" > '#{ctx.pid_file}'
    exit 0
    """)

    File.chmod!(executable, 0o755)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)
    baseline = ProcessManager.admission_counts()

    assert {:ok, _} = LspDiagnostics.diagnose_file(path, ctx.project)
    Enum.each(await_pids(ctx.pid_file, 100), &assert_process_gone(&1, 40))
    assert_capacity_restored(baseline)

    # Freed capacity admits the next launch, which runs to completion.
    File.rm!(ctx.pid_file)
    assert {:ok, _} = LspDiagnostics.diagnose_file(path, ctx.project)
    Enum.each(await_pids(ctx.pid_file, 100), &assert_process_gone(&1, 40))
    assert_capacity_restored(baseline)
  end

  test "a checker that kills its own anchor is reported, never signalled by stale id", ctx do
    executable = Path.join(ctx.operator_bin, "go")

    # The detached child keeps the group alive after the anchor is gone; the
    # runner must not fall back to signalling that numeric group id.
    File.write!(executable, """
    #!/bin/sh
    /bin/sleep 30 </dev/null >/dev/null 2>&1 &
    printf '%s\\n' "$!" > '#{ctx.pid_file}'
    kill -9 $PPID
    exit 0
    """)

    File.chmod!(executable, 0o755)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)

    assert {:ok, result} = LspDiagnostics.diagnose_file(path, ctx.project)
    assert result.raw_output =~ "proc://"
    [pid] = await_pids(ctx.pid_file, 100)
    assert {_, 0} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
  end

  test "an executable whose canonical path cannot be resolved is refused", ctx do
    marker = Path.join(ctx.tmp_dir, "checker-ran")
    marker_executable(ctx.operator_bin, "go", marker)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)
    exhausted = fn _path -> {:error, :symlink_limit} end

    assert {:ok, %{status: :skipped}} =
             LspDiagnostics.diagnose_file(path, ctx.project, realpath: exhausted)

    refute File.exists?(marker)

    # A real chain past the resolver's hop limit fails closed as well.
    chain =
      Enum.reduce(1..40, ctx.operator_bin, fn n, target ->
        link = Path.join(ctx.tmp_dir, "hop#{n}")
        File.ln_s!(target, link)
        link
      end)

    refute match?({:ok, _}, LemonCore.TrustedRoot.realpath(Path.join(chain, "go")))
    assert CodingAgent.Tools.CheckerRunner.inside_any?(Path.join(chain, "go"), [ctx.project])
    refute File.exists?(marker)
  end

  test "a checker that forks from its TERM handler is still killed on abort", ctx do
    executable = Path.join(ctx.operator_bin, "go")

    File.write!(executable, """
    #!/bin/sh
    trap '/bin/sleep 60 </dev/null >/dev/null 2>&1 & printf "%s\\n" "$!" >> "#{ctx.pid_file}"; exit 0' TERM
    /bin/sleep 60 &
    printf '%s %s\\n' "$$" "$!" >> '#{ctx.pid_file}'
    wait
    """)

    File.chmod!(executable, 0o755)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)
    signal = AbortSignal.new()
    baseline = ProcessManager.admission_counts()

    task =
      Task.async(fn ->
        LspDiagnostics.diagnose_file(path, ctx.project,
          diagnostics_timeout_ms: 60_000,
          signal: signal
        )
      end)

    await_pids(ctx.pid_file, 100)
    AbortSignal.abort(signal)
    assert {:ok, _} = Task.yield(task, 10_000)
    pids = String.split(File.read!(ctx.pid_file))
    assert length(pids) >= 2
    Enum.each(pids, &assert_process_gone(&1, 40))
    assert_capacity_restored(baseline)
  end

  test "the calling task dying mid-run still kills the group and releases capacity", ctx do
    sleeping_executable(ctx.operator_bin, "go", ctx.pid_file)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)
    baseline = ProcessManager.admission_counts()
    # A live session owner outlives the tool task.
    session = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(session, :kill) end)

    caller =
      spawn(fn ->
        LspDiagnostics.diagnose_file(path, ctx.project,
          diagnostics_timeout_ms: 60_000,
          session_id: "checker-caller-test",
          session_pid: session
        )
      end)

    pids = await_pids(ctx.pid_file, 100)
    Process.exit(caller, :kill)
    Enum.each(pids, &assert_process_gone(&1, 60))
    assert_capacity_restored(baseline)
  end

  test "fake end markers and a planted FIFO cannot fake or block the status", ctx do
    executable = Path.join(ctx.operator_bin, "go")
    fifo = Path.join(ctx.tmp_dir, "status")

    File.write!(executable, """
    #!/bin/sh
    printf '\\nlemon:0\\n\\n:0\\nAAAAAAAAAAAAAAAAAAAAAAAA:0\\n'
    /usr/bin/mkfifo '#{fifo}' 2>/dev/null
    for f in "${TMPDIR:-/tmp}"/lemon-checker-*; do [ -d "$f" ] && /usr/bin/mkfifo "$f/status" 2>/dev/null; done
    exit 3
    """)

    File.chmod!(executable, 0o755)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    path = Path.join(ctx.project, "main.go")
    File.write!(path, "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)

    assert {:ok, result} =
             LspDiagnostics.diagnose_file(path, ctx.project, diagnostics_timeout_ms: 10_000)

    assert result.command_exit_status == 3
    assert result.raw_output =~ "lemon:0"
  end

  defp assert_capacity_restored(baseline, attempts \\ 100) do
    counts = ProcessManager.admission_counts()

    cond do
      counts == baseline -> :ok
      attempts > 0 -> Process.sleep(50) && assert_capacity_restored(baseline, attempts - 1)
      true -> flunk("capacity not restored: #{inspect(counts)} vs #{inspect(baseline)}")
    end
  end

  test "lsp_diagnostics refuses before launch when its intent cannot be recorded", ctx do
    marker = Path.join(ctx.tmp_dir, "checker-ran")
    marker_executable(ctx.operator_bin, "go", marker)
    File.write!(Path.join(ctx.project, "go.mod"), "module fixture\n")
    File.write!(Path.join(ctx.project, "main.go"), "package main\n")
    System.put_env("PATH", ctx.operator_bin <> ":" <> ctx.previous_path)

    {:ok, tool} =
      CodingAgent.ToolRegistry.get_tool(ctx.project, "lsp_diagnostics",
        include_extensions: false,
        include_mcp: false,
        tool_policy: %{approval_mode: :yolo},
        tool_intent_recorder: fn _ -> {:error, :disk_full} end
      )

    result = tool.execute.("diag", %{"path" => "main.go"}, nil, nil)
    assert result.is_error
    assert result.details.reason == :intent_not_durable
    refute File.exists?(marker)
  end

  test "routed node tools read repo_local_tools from the node's global config only", ctx do
    previous = Application.get_env(:lemon_core, :paths)
    on_exit(fn -> Application.put_env(:lemon_core, :paths, previous || []) end)
    global = Path.join(ctx.tmp_dir, "global.toml")
    Application.put_env(:lemon_core, :paths, Keyword.put(previous || [], :global_config, global))

    File.mkdir_p!(Path.join(ctx.project, ".lemon"))

    File.write!(
      Path.join([ctx.project, ".lemon", "config.toml"]),
      "[runtime.tools.edit]\nrepo_local_tools = true\n"
    )

    File.write!(global, "")
    LemonCore.Config.reload(ctx.project)
    refute CodingAgent.ExecutionNode.ToolService.configured_repo_local_tools(ctx.project)

    File.write!(global, "[runtime.tools.edit]\nrepo_local_tools = true\n")
    LemonCore.Config.reload(ctx.project)
    assert CodingAgent.ExecutionNode.ToolService.configured_repo_local_tools(ctx.project)
  end

  defp assert_refused(ctx, cwd) do
    go = Path.join(cwd, "main.go")
    assert {:ok, %{status: :skipped}} = LspDiagnostics.diagnose_file(go, cwd)
    refute File.exists?(ctx.repo_marker)
  end

  defp sleeping_executable(dir, name, pid_file) do
    executable = Path.join(dir, name)

    File.write!(executable, """
    #!/bin/sh
    /bin/sleep 60 &
    printf '%s %s\\n' "$$" "$!" > '#{pid_file}'
    wait
    """)

    File.chmod!(executable, 0o755)
  end

  defp marker_executable(dir, name, marker) do
    executable = Path.join(dir, name)
    File.write!(executable, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(executable, 0o755)
  end

  defp managed?(executable) do
    Enum.any?(ProcessManager.list(status: :running), fn {_id, record} ->
      String.contains?(to_string(Map.get(record, :command)), executable)
    end)
  end

  defp await_pids(pid_file, attempts) do
    case File.read(pid_file) do
      {:ok, contents} when contents != "" ->
        String.split(contents)

      _ when attempts > 0 ->
        Process.sleep(50)
        await_pids(pid_file, attempts - 1)

      _ ->
        flunk("checker never started")
    end
  end

  defp assert_process_gone(pid, attempts) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, status} when status != 0 ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(50)
        assert_process_gone(pid, attempts - 1)

      _ ->
        flunk("process #{pid} still running")
    end
  end
end
