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
      runner = fn _, _, _ -> response end

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
                 assert {:ok, %{mode: mode}} = File.stat(Path.join(lock, "owner.json"))
                 assert Bitwise.band(mode, 0o777) == 0o600
                 :entered
               end
             )

    refute File.exists?(lock)
  end

  test "bounded input is delivered as a closed stdin pipe, never an argument" do
    input = String.duplicate("x", 43) <> "\n"
    assert {^input, 0} = Command.run("/bin/cat", [], [], input: input, timeout: 2_000)
  end
end
