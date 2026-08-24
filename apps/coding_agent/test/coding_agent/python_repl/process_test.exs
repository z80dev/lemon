defmodule CodingAgent.PythonRepl.ProcessTest do
  use ExUnit.Case, async: false

  alias CodingAgent.PythonRepl.Process, as: ReplProcess

  setup do
    real_kill = System.find_executable("kill") || raise "kill executable is required"
    real_sleep = System.find_executable("sleep") || raise "sleep executable is required"
    real_true = System.find_executable("true") || raise "true executable is required"
    shell = System.find_executable("sh") || raise "sh executable is required"

    tmp_dir =
      Path.join(System.tmp_dir!(), "python-repl-process-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(tmp_dir, "bin")
    log = Path.join(tmp_dir, "kill.log")
    shim = Path.join(bin_dir, "kill")

    File.mkdir_p!(bin_dir)
    File.write!(log, "")

    File.write!(
      shim,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$LEMON_REPL_KILL_LOG\"\nexec \"$LEMON_REPL_REAL_KILL\" \"$@\"\n"
    )

    File.chmod!(shim, 0o700)

    original_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin_dir <> ":" <> original_path)
    System.put_env("LEMON_REPL_KILL_LOG", log)
    System.put_env("LEMON_REPL_REAL_KILL", real_kill)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      System.delete_env("LEMON_REPL_KILL_LOG")
      System.delete_env("LEMON_REPL_REAL_KILL")
      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, log: log, sleep: real_sleep, shell: shell, true: real_true}
  end

  test "does not signal an interpreter already confirmed dead", ctx do
    process = start_process(ctx.true, [], ctx.tmp_dir)
    wait_until(fn -> not ReplProcess.alive?(process) end)
    File.write!(ctx.log, "")

    assert :ok = ReplProcess.terminate_tree(process)
    refute signal_sent?(ctx.log, "TERM")
    refute signal_sent?(ctx.log, "KILL")
  end

  test "terminates a live interpreter with SIGTERM", ctx do
    process = start_process(ctx.sleep, ["60"], ctx.tmp_dir)

    assert ReplProcess.alive?(process)
    assert :ok = ReplProcess.terminate_tree(process)
    assert signal_sent?(ctx.log, "TERM")
    refute ReplProcess.alive?(process)
  end

  test "escalates a live interpreter that ignores SIGTERM", ctx do
    process =
      start_process(ctx.shell, ["-c", "trap '' TERM; exec '#{ctx.sleep}' 60"], ctx.tmp_dir,
        term_grace_ms: 0,
        kill_grace_ms: 500
      )

    assert ReplProcess.alive?(process)
    assert :ok = ReplProcess.terminate_tree(process)
    assert signal_sent?(ctx.log, "TERM")
    assert signal_sent?(ctx.log, "KILL")
    refute ReplProcess.alive?(process)
  end

  defp start_process(program, args, cwd, opts \\ []) do
    assert {:ok, process} =
             ReplProcess.start(
               Keyword.merge([program: program, args: args, cwd: cwd, term_grace_ms: 100], opts)
             )

    process
  end

  defp signal_sent?(log, signal) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.any?(&String.starts_with?(&1, "-#{signal} "))
  end

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until(fun, deadline, timeout)
  end

  defp wait_until(fun, deadline, timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met within #{timeout}ms")

      true ->
        Process.sleep(10)
        wait_until(fun, deadline, timeout)
    end
  end
end
