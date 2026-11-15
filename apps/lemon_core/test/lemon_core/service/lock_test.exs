defmodule LemonCore.Service.LockTest do
  use ExUnit.Case, async: true
  alias LemonCore.Service.{Command, Lock, Role}
  @moduletag :tmp_dir
  @started "Tue Nov 10 12:00:00 2026"

  test "a live owner cannot be reclaimed and errors are not proof of death", %{tmp_dir: home} do
    lock = Path.join([home, ".lemon/run/service", "test.lock"])
    File.mkdir_p!(lock)

    File.write!(
      Path.join(lock, "owner.json"),
      Jason.encode!(%{pid: 123, started_at: @started, executable: "/bin/beam.smp"})
    )

    File.chmod!(Path.join(lock, "owner.json"), 0o600)

    for response <- [{@started, 0}, {"permission denied", 1}, {"", 127}] do
      runner = fn
        "ps", ["-p", "123", "-o", "lstart="], _ -> response
        command, args, opts -> identity_runner(command, args, opts)
      end

      assert {:error, :service_locked} =
               Lock.with_lock("test", [home: home, uid: "501", command_runner: runner], fn ->
                 flunk("must not enter")
               end)

      assert File.exists?(Path.join(lock, "owner.json"))
    end
  end

  test "dead-owner reclaim is private and releases its lease", %{tmp_dir: home} do
    lock = Path.join([Role.run_dir(home: home), "test.lock"])
    File.mkdir_p!(lock)

    File.write!(
      Path.join(lock, "owner.json"),
      Jason.encode!(%{pid: 123, started_at: @started, executable: "/bin/beam.smp"})
    )

    File.chmod!(Path.join(lock, "owner.json"), 0o600)

    runner = fn
      "ps", ["-p", "123", "-o", "lstart="], _ -> {"", 1}
      "ps", _, _ -> {"501 #{@started} /bin/beam.smp\n", 0}
    end

    assert :entered =
             Lock.with_lock(
               "test",
               [home: home, uid: "501", os: :darwin, command_runner: runner],
               fn ->
                 [owner] = File.ls!(lock)
                 assert String.starts_with?(owner, "owner.")
                 assert {:ok, %{mode: mode}} = File.stat(Path.join(lock, owner))
                 assert Bitwise.band(mode, 0o777) == 0o600
                 :entered
               end
             )

    refute File.exists?(lock)
  end

  test "recovers a killed BEAM holder while its OS process is still alive", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    opts = lock_options()
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        Lock.with_lock_path(path, opts, fn ->
          send(parent, {:held, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive {:held, ^holder}, 1_000
    assert {:error, :lock_timeout} = Lock.with_lock_path(path, opts, fn -> flunk("held") end)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 1_000
    assert File.dir?(path)

    assert :recovered = Lock.with_lock_path(path, opts, fn -> :recovered end)
    refute File.exists?(path)
  end

  test "holds a complete private owner record and releases on callback failure", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    opts = lock_options()

    assert_raise RuntimeError, "callback failed", fn ->
      Lock.with_lock_path(path, opts, fn ->
        [owner] = File.ls!(path)
        assert String.match?(owner, ~r/^owner\.[0-9a-f]{32}\.json$/)
        assert {:ok, record} = LemonCore.Service.Identity.read_json(Path.join(path, owner))
        assert record["pid"] == String.to_integer(System.pid())
        assert record["beam_pid"] == to_string(:erlang.pid_to_list(self()))
        assert record["node"] == to_string(node())
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700
        raise "callback failed"
      end)
    end

    assert File.ls!(home) == []
    assert :again = Lock.with_lock_path(path, opts, fn -> :again end)
  end

  test "does not change the permissions of a caller's data directory", %{tmp_dir: home} do
    File.chmod!(home, 0o755)
    path = Path.join(home, "state.lock")
    assert :ok = Lock.with_lock_path(path, lock_options(), fn -> :ok end)
    assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o755
  end

  test "reports filesystem and identity failures without entering", %{tmp_dir: home} do
    path = Path.join([home, "missing", "state.lock"])

    assert {:error, {:lock_failed, :enoent}} =
             Lock.with_lock_path(path, lock_options(), fn -> flunk("missing parent") end)

    opts = Keyword.put(lock_options(), :command_runner, fn _, _, _ -> {"unavailable", 1} end)

    assert {:error, {:lock_failed, :process_identity_unverified}} =
             Lock.with_lock_path(Path.join(home, "state.lock"), opts, fn ->
               flunk("no identity")
             end)

    assert File.ls!(home) == []
  end

  test "malformed ownership is never evidence of death", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    File.mkdir!(path)
    owner = Path.join(path, "owner.json")
    File.write!(owner, "{}")
    File.chmod!(owner, 0o600)

    assert {:error, :lock_timeout} =
             Lock.with_lock_path(path, lock_options(), fn -> flunk("unverified owner") end)

    assert File.read!(owner) == "{}"
    assert File.ls!(home) == ["state.lock"]
  end

  test "a foreign OS owner is not reclaimed using a dead local BEAM pid", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    {holder, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 1_000
    File.mkdir!(path)
    owner = Path.join(path, "owner.json")

    File.write!(
      owner,
      Jason.encode!(%{
        pid: String.to_integer(System.pid()) + 1,
        started_at: @started,
        beam_pid: to_string(:erlang.pid_to_list(holder)),
        node: to_string(node())
      })
    )

    File.chmod!(owner, 0o600)

    assert {:error, :lock_timeout} =
             Lock.with_lock_path(path, lock_options(), fn -> flunk("foreign owner is alive") end)

    assert File.exists?(owner)
  end

  test "a late reclaimer cannot delete a replacement holder", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    File.mkdir!(path)
    owner = Path.join(path, "owner.json")
    File.write!(owner, Jason.encode!(%{pid: 123, started_at: @started}))
    File.chmod!(owner, 0o600)
    parent = self()

    runner = fn
      "ps", ["-p", "123", "-o", "lstart="], _ ->
        send(parent, {:checking_stale, self()})

        receive do
          :confirm_dead -> {"", 1}
        end

      command, args, opts ->
        identity_runner(command, args, opts)
    end

    late =
      Task.async(fn ->
        Lock.with_lock_path(path, lock_options(command_runner: runner), fn ->
          flunk("replacement held")
        end)
      end)

    assert_receive {:checking_stale, late_pid}, 1_000

    dead_runner = fn
      "ps", ["-p", "123", "-o", "lstart="], _ -> {"", 1}
      command, args, opts -> identity_runner(command, args, opts)
    end

    assert :replacement =
             Lock.with_lock_path(path, lock_options(command_runner: dead_runner), fn ->
               [replacement] = File.ls!(path)
               send(late_pid, :confirm_dead)
               assert {:error, :lock_timeout} = Task.await(late)
               assert File.exists?(Path.join(path, replacement))
               :replacement
             end)

    refute File.exists?(path)
  end

  test "waiting for a live owner respects the finite caller budget", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    opts = lock_options()

    assert :held =
             Lock.with_lock_path(path, opts, fn ->
               waiter =
                 Task.async(fn ->
                   Lock.with_lock_path(path, Keyword.put(opts, :timeout, 1), fn ->
                     flunk("must not enter while held")
                   end)
                 end)

               assert {:error, :lock_timeout} = Task.await(waiter, 1_000)
               :held
             end)

    assert File.ls!(home) == []
  end

  test "reused OS pid is checked by start time, not a live local BEAM pid", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    File.mkdir!(path)
    owner = Path.join(path, "owner.json")

    File.write!(
      owner,
      Jason.encode!(%{
        pid: String.to_integer(System.pid()),
        started_at: "Mon Nov 9 12:00:00 2026",
        beam_pid: to_string(:erlang.pid_to_list(self())),
        node: to_string(node())
      })
    )

    File.chmod!(owner, 0o600)
    assert :reclaimed = Lock.with_lock_path(path, lock_options(), fn -> :reclaimed end)
    refute File.exists?(path)
  end

  test "releases before propagating callback throws and exits", %{tmp_dir: home} do
    path = Path.join(home, "state.lock")
    opts = lock_options()

    assert catch_throw(Lock.with_lock_path(path, opts, fn -> throw(:thrown) end)) == :thrown
    refute File.exists?(path)
    assert catch_exit(Lock.with_lock_path(path, opts, fn -> exit(:stopped) end)) == :stopped
    assert File.ls!(home) == []
  end

  test "bounded input is delivered as a closed stdin pipe, never an argument" do
    input = String.duplicate("x", 43) <> "\n"
    assert {^input, 0} = Command.run("/bin/cat", [], [], input: input, timeout: 2_000)
  end

  defp lock_options(overrides \\ []) do
    Keyword.merge([uid: "501", os: :darwin, command_runner: &identity_runner/3], overrides)
  end

  defp identity_runner("ps", [_, _, "-o", "lstart="], _), do: {@started, 0}
  defp identity_runner("ps", _, _), do: {"501 #{@started} /bin/beam.smp\n", 0}
end
