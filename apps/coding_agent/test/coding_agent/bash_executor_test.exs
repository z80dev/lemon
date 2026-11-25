defmodule CodingAgent.BashExecutorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.BashExecutor
  alias CodingAgent.BashExecutor.Result
  alias LemonAgent.AbortSignal
  alias LemonCore.ProcessGroup

  @moduletag :tmp_dir

  # on_chunk runs outside the caller; an Agent makes delivery synchronous.
  defp collect_chunks do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {agent, fn chunk -> Agent.update(agent, &[chunk | &1]) end}
  end

  defp received_chunks(agent), do: agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.join()

  @tag :python3
  test "stream relay captures authentic stdout, stderr and shell exit status" do
    assert {:ok, result} =
             BashExecutor.execute("printf 'out'; printf 'err' >&2; exit 3", "/tmp",
               capture_streams: true
             )

    assert result.stdout == "out"
    assert result.stderr == "err"
    assert result.exit_code == 3
    assert result.output in ["outerr", "errout"]
  end

  @tag :python3
  test "stream relay bounds each capture independently" do
    assert {:ok, result} =
             BashExecutor.execute("printf '123456789'; printf 'abcdefghi' >&2", "/tmp",
               capture_streams: true,
               max_bytes: 4
             )

    assert result.stdout == "1234"
    assert result.stderr == "abcd"
    assert result.truncated
  end

  describe "execute/3" do
    test "executes simple command and returns Result struct" do
      {:ok, result} = BashExecutor.execute("echo hello", "/tmp")
      assert %Result{} = result
      assert result.output == "hello\n"
      assert result.exit_code == 0
      assert result.cancelled == false
      assert result.truncated == false
      assert result.full_output_path == nil
    end

    test "returns the command output verbatim for varied command forms", %{tmp_dir: tmp_dir} do
      long_arg = String.duplicate("x", 10_000)

      for {command, expected} <- [
            {"echo error >&2", "error\n"},
            {"printf test", "test"},
            {"echo line1; echo line2", "line1\nline2\n"},
            {"echo line1\necho line2", "line1\nline2\n"},
            {"echo 'hello world'", "hello world\n"},
            {"echo 'hello' | tr 'h' 'H'", "Hello\n"},
            {~s(echo "it's a \\"test\\""), ~s(it's a "test"\n)},
            {"echo \"#{long_arg}\"", long_arg <> "\n"}
          ] do
        assert {:ok, %{output: ^expected, exit_code: 0}} = BashExecutor.execute(command, tmp_dir)
      end
    end

    test "propagates exit codes", %{tmp_dir: tmp_dir} do
      for {command, code} <- [
            {"exit 0", 0},
            {"exit 42", 42},
            {"exit 255", 255},
            {"nonexistent_cmd_xyz_123", 127}
          ] do
        assert {:ok, %{exit_code: ^code, cancelled: false}} =
                 BashExecutor.execute(command, tmp_dir)
      end
    end

    test "empty and whitespace-only commands succeed without output", %{tmp_dir: tmp_dir} do
      for command <- ["", "   ", "true"] do
        assert {:ok, %{exit_code: 0, cancelled: false, output: ""}} =
                 BashExecutor.execute(command, tmp_dir)
      end
    end

    test "respects working directory" do
      {:ok, result} = BashExecutor.execute("pwd", "/tmp")
      assert result.output =~ "/tmp"
    end

    test "a missing working directory fails without running the command" do
      assert {:ok, result} = BashExecutor.execute("echo ran", "/nonexistent/path/xyz")
      assert result.exit_code != 0
      refute result.output =~ "ran"
    end

    test "handles output exceeding OS pipe buffer without deadlock" do
      # Generate output larger than OS pipe buffer (64KB on Linux, 16KB on macOS).
      # This is a regression test for pipe deadlock issues.
      command = """
      if command -v python3 >/dev/null 2>&1; then
        python3 -c "print('A' * 131072)"
      elif command -v python >/dev/null 2>&1; then
        python -c "print('A' * 131072)"
      else
        dd if=/dev/zero bs=1024 count=130 2>/dev/null | tr '\\0' 'A'
      fi
      """

      task = Task.async(fn -> BashExecutor.execute(command, "/tmp", max_bytes: 10_000) end)

      case Task.yield(task, 10_000) do
        {:ok, {:ok, result}} ->
          assert result.exit_code == 0
          assert result.truncated == true
          assert result.output =~ "AAAA"
          if result.full_output_path, do: File.rm(result.full_output_path)

        {:ok, {:error, reason}} ->
          flunk("Command failed: #{inspect(reason)}")

        nil ->
          Task.shutdown(task, :brutal_kill)
          flunk("Command timed out - possible pipe deadlock")
      end
    end
  end

  describe "streaming" do
    test "on_chunk receives sanitized output in order", %{tmp_dir: tmp_dir} do
      {ref, on_chunk} = collect_chunks()

      {:ok, result} =
        BashExecutor.execute(
          "for i in 1 2 3 4 5; do echo \"line$i\"; sleep 0.01; done; printf '\\033[31mred\\033[0m'",
          tmp_dir,
          on_chunk: on_chunk
        )

      combined = received_chunks(ref)
      assert combined == "line1\nline2\nline3\nline4\nline5\nred"
      assert result.output == combined
    end

    test "a raising on_chunk callback is returned as an error", %{tmp_dir: tmp_dir} do
      assert {:error, %RuntimeError{message: "callback error"}} =
               BashExecutor.execute("echo test", tmp_dir,
                 on_chunk: fn _chunk -> raise "callback error" end
               )
    end

    test "concurrent executions keep output and callbacks isolated", %{tmp_dir: tmp_dir} do
      tasks =
        for name <- ["task1_output", "task2_output"] do
          Task.async(fn ->
            {ref, on_chunk} = collect_chunks()
            {:ok, result} = BashExecutor.execute("echo #{name}", tmp_dir, on_chunk: on_chunk)
            {name, result.output, received_chunks(ref)}
          end)
        end

      for {name, output, chunks} <- Task.await_many(tasks, 5_000) do
        assert output == name <> "\n"
        assert chunks == name <> "\n"
      end
    end
  end

  describe "timeout" do
    test "kills the command after the timeout and keeps partial output", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 1000); do echo line$i; done; sleep 10",
          tmp_dir,
          timeout: 2_000
        )

      assert result.cancelled == true
      assert result.exit_code == nil
      assert result.output =~ "line1\n"
    end

    test "zero, negative or generous timeouts let the command finish", %{tmp_dir: tmp_dir} do
      for {command, timeout} <- [{"sleep 0.1", 5_000}, {"echo fast", 0}, {"echo fast", -1000}] do
        assert {:ok, %{cancelled: false, exit_code: 0}} =
                 BashExecutor.execute(command, tmp_dir, timeout: timeout)
      end
    end
  end

  describe "abort signal" do
    test "handles abort signal" do
      signal = AbortSignal.new()
      task = Task.async(fn -> BashExecutor.execute("sleep 10", "/tmp", signal: signal) end)

      Process.sleep(50)
      AbortSignal.abort(signal)

      {:ok, result} = Task.await(task, 5_000)
      assert result.cancelled == true
      assert result.exit_code == nil
    end

    test "an already aborted signal cancels without an exit code", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      assert {:ok, %{cancelled: true, exit_code: nil}} =
               BashExecutor.execute("echo test", tmp_dir, signal: signal)
    end

    test "abort preserves partial output", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      parent = self()

      task =
        Task.async(fn ->
          BashExecutor.execute(
            "echo before_abort; sleep 5; echo after_abort",
            tmp_dir,
            signal: signal,
            on_chunk: fn chunk -> send(parent, {:chunk, chunk}) end
          )
        end)

      # Abort only once the command has produced output (a fixed sleep races
      # shell startup under full-suite load).
      assert_receive {:chunk, _chunk}, 5_000
      AbortSignal.abort(signal)

      {:ok, result} = Task.await(task, 5_000)

      assert result.cancelled == true
      assert result.output =~ "before_abort"
      refute result.output =~ "after_abort"
    end

    test "abort from the first output callback is observed without another chunk", %{
      tmp_dir: tmp_dir
    } do
      signal = AbortSignal.new()
      on_chunk = fn _chunk -> AbortSignal.abort(signal) end

      assert {:ok, result} =
               BashExecutor.execute("printf ready; sleep 30", tmp_dir,
                 signal: signal,
                 on_chunk: on_chunk,
                 timeout: 5_000
               )

      assert result.cancelled
      refute result.timed_out
      assert result.output =~ "ready"
    end

    test "concurrent abort signals are independent", %{tmp_dir: tmp_dir} do
      signal1 = AbortSignal.new()
      signal2 = AbortSignal.new()

      task1 = Task.async(fn -> BashExecutor.execute("sleep 5", tmp_dir, signal: signal1) end)

      task2 =
        Task.async(fn ->
          BashExecutor.execute("echo independent; sleep 0.5", tmp_dir, signal: signal2)
        end)

      Process.sleep(50)
      AbortSignal.abort(signal1)

      {:ok, result1} = Task.await(task1, 5_000)
      {:ok, result2} = Task.await(task2, 5_000)

      assert result1.cancelled == true
      assert result2.cancelled == false
      assert result2.exit_code == 0
    end
  end

  describe "output truncation" do
    test "truncation preserves head and tail and archives the full output", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 3000); do echo line$i; done",
          tmp_dir,
          max_bytes: 10_000,
          max_lines: 100
        )

      assert result.truncated == true
      assert result.output =~ "line1\n"
      assert result.output =~ "line3000"
      assert result.output =~ "line2999"
      assert result.output =~ "showing head and tail"
      refute result.output =~ "line1500\n"

      assert File.read!(result.full_output_path) ==
               Enum.map_join(1..3000, "", &"line#{&1}\n")

      File.rm!(result.full_output_path)
    end
  end

  describe "sanitize_output/1" do
    test "strips ANSI and control codes, drops carriage returns, keeps text" do
      for {input, expected} <- [
            {"\e[31mred\e[0m text", "red text"},
            {"\e[1mbold\e[0m \e[4munderline\e[0m", "bold underline"},
            {"\e[2Jcleared\e[H", "cleared"},
            {"line1\r\nline2\r\n", "line1\nline2\n"},
            {"progress\rprogress2\rdone", "progressprogress2done"},
            {"before\0after", "beforeafter"},
            {"normal\abell\bbackspace", "normalbellbackspace"},
            {"col1\tcol2\nrow2col1\trow2col2", "col1\tcol2\nrow2col1\trow2col2"},
            {"hello world 123", "hello world 123"},
            {"", ""}
          ] do
        assert BashExecutor.sanitize_output(input) == expected, inspect(input)
      end
    end

    test "replaces invalid UTF-8 bytes" do
      assert BashExecutor.sanitize_output(<<"hello", 255, 254>>) == "hello\uFFFD\uFFFD"
    end
  end

  describe "truncate_tail/2" do
    test "keeps last N lines when line limit exceeded" do
      content = Enum.map_join(1..100, "\n", &"line #{&1}")

      {truncated, was_truncated, info} = BashExecutor.truncate_tail(content, max_lines: 10)

      assert was_truncated == true
      assert info.total_lines == 100
      assert info.total_bytes == byte_size(content)
      assert info.output_lines == 10
      assert info.output_bytes > 0
      assert truncated =~ "[Output truncated."
      assert truncated =~ "line 100"
      assert truncated =~ "line 91"
      refute truncated =~ "line 90\n"
    end

    test "returns content unchanged within or exactly at the limits" do
      at_limit = Enum.map_join(1..2000, "\n", &"line #{&1}")

      for content <- ["short output", at_limit] do
        assert {^content, false, %{output_lines: lines, total_lines: lines}} =
                 BashExecutor.truncate_tail(content, max_lines: 2000)
      end

      assert {"", false, %{total_lines: 1, total_bytes: 0}} = BashExecutor.truncate_tail("")
    end

    test "truncates by bytes when byte limit exceeded" do
      content = String.duplicate("x", 60_000)

      {truncated, was_truncated, info} = BashExecutor.truncate_tail(content, max_bytes: 10_000)

      assert was_truncated == true
      assert info.total_bytes == 60_000
      assert info.output_bytes <= 10_000
      assert truncated =~ "[Output truncated."
    end
  end

  test "get_shell_config/0 returns a shell and its command flag" do
    {shell, args} = BashExecutor.get_shell_config()
    assert is_binary(shell)
    assert "-c" in args or "/C" in args
  end

  describe "ProcessGroup.terminate/2" do
    test "handles killing non-existent process gracefully" do
      assert ProcessGroup.terminate(999_999_999, signal: :sigkill) == :ok
    end

    test "can kill actual process" do
      port =
        Port.open(
          {:spawn_executable, "/bin/sleep"},
          [:binary, :exit_status, {:args, ["10"]}]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert ProcessGroup.terminate(os_pid, signal: :sigkill) == :ok
      assert_receive {^port, {:exit_status, _}}, 1_000
    end
  end

  describe "pty option" do
    test "pty mode runs in the working directory and streams output" do
      {ref, on_chunk} = collect_chunks()

      {:ok, result} =
        BashExecutor.execute("pwd; echo pty_stream", "/tmp", pty: true, on_chunk: on_chunk)

      assert %Result{cancelled: false, exit_code: 0} = result
      assert result.output =~ "/tmp"
      assert result.output =~ "pty_stream"
      assert received_chunks(ref) =~ "pty_stream"
    end

    test "pty: false behaves like the default pipe mode" do
      assert {:ok, %Result{output: "no_pty\n", exit_code: 0}} =
               BashExecutor.execute("echo no_pty", "/tmp", pty: false)
    end

    test "pty mode does not cancel non-zero exits" do
      assert {:ok, %Result{cancelled: false}} = BashExecutor.execute("exit 42", "/tmp", pty: true)
    end

    test "pty mode handles timeout" do
      {:ok, result} = BashExecutor.execute("sleep 10", "/tmp", pty: true, timeout: 200)
      assert result.cancelled == true
    end
  end
end

defmodule CodingAgent.BashExecutorTrackingTest do
  use ExUnit.Case, async: false

  alias CodingAgent.BashExecutor
  alias LemonCore.{NativeProcess, ProcessGroup}

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous = Application.fetch_env(:lemon_core, :native_process_ledger)

    on_exit(fn ->
      if pid = Process.whereis(NativeProcess), do: GenServer.stop(pid)

      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end
    end)

    %{ledger: Path.join(directory, "native.dets")}
  end

  test "guarded Bash launches retain a durable group witness", %{ledger: ledger, tmp_dir: cwd} do
    assert :ok = NativeProcess.configure!(ledger)
    assert {:ok, result} = BashExecutor.execute("printf tracked", cwd)
    assert result.output == "tracked"
    assert result.exit_code == 0
    assert [{_id, record, %{}}] = NativeProcess.snapshot()
    assert record.backend == :local
    assert ProcessGroup.valid_identity?(record.workload_identity)
  end

  test "an unavailable ledger returns an error without launching or hanging the guardian", %{
    ledger: ledger,
    tmp_dir: cwd
  } do
    Application.put_env(:lemon_core, :native_process_ledger, ledger)
    task = Task.async(fn -> BashExecutor.execute("touch launched", cwd) end)
    assert {:error, %RuntimeError{}} = Task.await(task, 5_000)
    refute File.exists?(Path.join(cwd, "launched"))
  end

  test "PTY launches retain an unsupported whole-workload intent", %{ledger: ledger, tmp_dir: cwd} do
    assert :ok = NativeProcess.configure!(ledger)
    assert {:ok, result} = BashExecutor.execute("printf tracked", cwd, pty: true)
    assert result.output =~ "tracked"

    assert Enum.any?(NativeProcess.snapshot(), fn {_id, record, %{}} ->
             record.backend == :unsupported and record.capacity_held and
               not record.termination_confirmed and is_nil(record.workload_identity)
           end)
  end
end

if match?({:unix, _}, :os.type()) do
  defmodule CodingAgent.BashExecutorProcessGroupTest do
    # Process-group cleanup: a backgrounded child whose parent shell already
    # exited is reparented to init, so a `pgrep -P` walk cannot find it, but it
    # still belongs to the shell's process group.
    use ExUnit.Case, async: true

    alias CodingAgent.BashExecutor
    alias LemonAgent.AbortSignal

    @moduletag :tmp_dir

    # The inner `sh` records the child's pid and exits at once, orphaning the
    # `sleep`; the outer shell stays alive so the command is still running.
    defp orphaning_command(pid_file, outer \\ "sleep 300") do
      "sh -c 'sleep 300 & echo $! > \"$0\"' '#{pid_file}'; #{outer}"
    end

    defp await_pid(pid_file) do
      wait_until("pid file", fn ->
        with {:ok, content} <- File.read(pid_file),
             {pid, ""} <- Integer.parse(String.trim(content)) do
          pid
        else
          _ -> nil
        end
      end)
    end

    defp wait_until(label, fun, attempts \\ 400) do
      cond do
        value = fun.() ->
          value

        attempts == 0 ->
          flunk("timed out waiting for #{label}")

        true ->
          Process.sleep(25)
          wait_until(label, fun, attempts - 1)
      end
    end

    # `kill -0` succeeds for zombies, which are already dead for our purposes.
    defp os_alive?(pid) do
      pid = Integer.to_string(pid)

      case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
        {_, 0} ->
          {stat, _} = System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true)
          not String.starts_with?(String.trim(stat), "Z")

        _ ->
          false
      end
    end

    defp await_gone(pid), do: wait_until("pid #{pid} to exit", fn -> not os_alive?(pid) end)

    test "abort stops a backgrounded child that outlived its parent shell", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "child.pid")
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          BashExecutor.execute(orphaning_command(pid_file), dir, signal: signal)
        end)

      child = await_pid(pid_file)
      assert os_alive?(child)

      AbortSignal.abort(signal)
      assert {:ok, result} = Task.await(task, 10_000)
      assert result.cancelled == true

      await_gone(child)
    end

    test "killing the tool worker stops a backgrounded child that outlived its parent shell",
         %{tmp_dir: dir} do
      pid_file = Path.join(dir, "child.pid")
      worker = spawn(fn -> BashExecutor.execute(orphaning_command(pid_file), dir) end)

      child = await_pid(pid_file)
      assert os_alive?(child)

      Process.exit(worker, :kill)
      await_gone(child)
    end

    test "timeout escalates to SIGKILL for a group that ignores SIGTERM", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "child.pid")

      command =
        "trap '' TERM; sh -c 'trap \"\" TERM; sleep 300 & echo $! > \"$0\"' '#{pid_file}'; " <>
          "while :; do sleep 1; done"

      task = Task.async(fn -> BashExecutor.execute(command, dir, timeout: 1_000) end)

      child = await_pid(pid_file)
      assert {:ok, result} = Task.await(task, 15_000)
      assert result.cancelled == true
      assert result.timed_out == true

      await_gone(child)
    end
  end
end
