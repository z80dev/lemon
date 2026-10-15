defmodule LemonOmp.ManagerWorktreeCleanupTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  test "ended snapshot eviction cannot discard worktree cleanup ownership" do
    use_fake_omp()
    cwd = workspace!()
    git!(cwd, ["init", "--quiet"])
    File.write!(Path.join(cwd, ".gitignore"), ".fake_omp*\n")
    git!(cwd, ["add", "."])

    git!(cwd, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    assert {:ok, wire} = LemonOmp.start(%{cwd: cwd, prompt: "HOLD", isolate: true})
    pid = session_pid(wire["id"])
    kill_on_exit(fake_pid(wire["cwd"]))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # Fill the ended-session cache before publishing a terminal snapshot whose
    # Session has not yet finished cleanup (or even terminated).
    for index <- 1..55 do
      ended =
        Map.merge(wire, %{
          "id" => "omp_eviction_fixture_#{index}",
          "status" => "closed",
          "worktree" => nil,
          "endedAt" => wire["startedAt"] - 10_000
        })

      LemonOmp.Manager.publish(self(), ended, "exited")
    end

    LemonOmp.Manager.publish(pid, Map.put(wire, "status", "failed"), "exited")
    :sys.get_state(LemonOmp.Manager)
    assert {:ok, ^pid, _} = LemonOmp.Manager.lookup(wire["id"])
    Process.exit(pid, :kill)
    ended = await_wire(wire["id"], &(get_in(&1, ["worktree", "kept"]) == false))
    assert ended["status"] == "failed"
    refute File.exists?(wire["cwd"])
  end

  defp git!(cwd, args) do
    assert {_, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
  end
end
