defmodule LemonOmp.TestSupport do
  @moduledoc """
  Helpers for lemon_omp tests: temp workspaces, the fake `omp` binary
  (`test/support/fake_omp`), application-env overrides that restore
  themselves, and OS-process checks.

  Call these from a test or `setup` block: they register `on_exit` callbacks.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @fake_omp Path.expand("fake_omp", __DIR__)

  @doc "Absolute path of the fake omp executable."
  def fake_omp, do: @fake_omp

  @doc "A fresh temp directory, removed after the test."
  def tmp_dir!(prefix \\ "lemon_omp_test") do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc """
  A temp workspace whose fake omp starts in `mode`. After the test, live
  sessions are closed before the directory is removed.
  """
  def workspace!(mode \\ "normal") do
    dir = Path.join(System.tmp_dir!(), "lemon_omp_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".fake_omp_mode"), mode)

    on_exit(fn ->
      close_all_sessions()
      File.rm_rf(dir)
    end)

    dir
  end

  @doc "Set `config :lemon_omp, key` for this test only."
  def put_app_env(key, value) do
    previous = Application.fetch_env(:lemon_omp, key)
    Application.put_env(:lemon_omp, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:lemon_omp, key, old)
        :error -> Application.delete_env(:lemon_omp, key)
      end
    end)
  end

  @doc """
  Point `:executable` at the fake binary and, after the test, close every
  live session and SIGKILL any fake process that is still around.
  """
  def use_fake_omp do
    put_app_env(:executable, @fake_omp)

    for key <- ~w(LEMON_OMP_BIN LEMON_OMP_SESSION_DIR) do
      previous = System.get_env(key)
      System.delete_env(key)

      on_exit(fn ->
        if previous,
          do: System.put_env(key, previous),
          else: System.delete_env(key)
      end)
    end

    on_exit(&close_all_sessions/0)
  end

  def close_all_sessions do
    for {_id, pid, wire} <- LemonOmp.Manager.all(), LemonOmp.Manager.live?(pid, wire) do
      LemonOmp.Session.close(pid)
    end

    :ok
  end

  @doc "The OS pid the fake recorded in `dir` (waits for the file)."
  def fake_pid(dir, file \\ ".fake_omp.pid") do
    path = Path.join(dir, file)
    wait_until(fn -> File.exists?(path) and File.read!(path) =~ ~r/^\d+\n/ end)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  @doc "Lines the fake received on stdin, decoded."
  def received(dir) do
    case File.read(Path.join(dir, ".fake_omp.log")) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  @doc "Whether an OS process exists (and is not a zombie)."
  def os_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  @doc "SIGKILL leftovers so a failing test never leaks processes."
  def kill_on_exit(os_pids) do
    on_exit(fn ->
      for pid <- List.wrap(os_pids), os_alive?(pid) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end)
  end

  @doc "Poll `fun` until it returns truthy or `timeout_ms` passes."
  def wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise ExUnit.AssertionError, message: "condition not met in time"

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  @doc "Poll the snapshot of `id` until `pred` holds; returns it."
  def await_wire(id, pred, timeout_ms \\ 5_000) do
    wait_until(
      fn ->
        case LemonOmp.get(id) do
          {:ok, wire} -> pred.(wire)
          _ -> false
        end
      end,
      timeout_ms
    )

    {:ok, wire} = LemonOmp.get(id)
    wire
  end

  @doc "The live `LemonOmp.Session` pid for a Lemon invocation id."
  def session_pid(id) do
    {:ok, pid, _wire} = LemonOmp.Manager.lookup(id)
    pid
  end
end
