defmodule LemonSkills.ServiceLockTest do
  use ExUnit.Case, async: true

  alias LemonCore.FileLock, as: Lock
  alias LemonSkills.Audit.State
  alias LemonSkills.{Lockfile, Usage}

  @moduletag :tmp_dir

  test "all metadata writers recover their shared lock after a holder is killed", %{tmp_dir: cwd} do
    scope = {:project, cwd}
    usage_opts = [scope: :project, cwd: cwd]

    writers = [
      {Lockfile.path(scope), fn -> Lockfile.put(scope, %{"key" => "skill"}) end},
      {State.path(scope), fn -> State.put(scope, :skill, "skill", %{"status" => "pass"}) end},
      {Usage.usage_file(usage_opts), fn -> Usage.set_state("skill", :pinned, usage_opts) end}
    ]

    for {path, write} <- writers do
      File.mkdir_p!(Path.dirname(path))
      lock_path = path <> ".lock"
      parent = self()

      {holder, monitor} =
        spawn_monitor(fn ->
          Lock.with_lock_path(lock_path, [], fn ->
            send(parent, {:held, self()})

            receive do
              :release -> :ok
            end
          end)
        end)

      on_exit(fn -> Process.exit(holder, :kill) end)
      assert_receive {:held, ^holder}, 5_000
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 1_000
      assert File.dir?(lock_path)
      assert :ok = write.()
      refute File.exists?(lock_path)
    end

    assert {:ok, %{"key" => "skill"}} = Lockfile.get(scope, "skill")
    assert {:ok, %{"status" => "pass"}} = State.get(scope, :skill, "skill")
    assert Usage.pinned?("skill", usage_opts)
  end
end
