defmodule LemonCore.OrphanReaperTest do
  use ExUnit.Case, async: true

  alias LemonCore.OrphanReaper

  describe "workspace_dir/0" do
    test "returns path under ~/.lemon/agent/workspace" do
      dir = OrphanReaper.workspace_dir()
      assert String.ends_with?(dir, "/.lemon/agent/workspace")
      assert String.starts_with?(dir, "/")
    end
  end

  describe "running under supervision tree" do
    test "is started and registered" do
      pid = Process.whereis(OrphanReaper)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "handles :sweep message without crashing" do
      pid = Process.whereis(OrphanReaper)
      send(pid, :sweep)
      Process.sleep(200)
      assert Process.alive?(pid)
    end

    test "ignores unknown messages" do
      pid = Process.whereis(OrphanReaper)
      send(pid, :unknown_message)
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end
end
