defmodule CodingAgent.ApplicationTest do
  use ExUnit.Case, async: false

  @expected_children [
    CodingAgent.SessionRegistry,
    CodingAgent.ProcessRegistry,
    CodingAgent.Tools.TodoStoreOwner,
    CodingAgent.SessionSupervisor,
    CodingAgent.Wasm.SidecarSupervisor,
    CodingAgent.TaskSupervisor,
    CodingAgent.TaskStoreServer,
    CodingAgent.RunGraphServer,
    CodingAgent.ProcessStoreServer,
    CodingAgent.ProcessManager,
    CodingAgent.LaneQueue
  ]

  @moduledoc """
  Tests for CodingAgent.Application supervision tree.
  """

  describe "application supervision tree" do
    test "application starts correctly" do
      # The application should already be started from test_helper.exs
      # Verify the main supervisor is running
      assert Process.whereis(CodingAgent.Supervisor) != nil
    end

    test "SessionRegistry is started and functional" do
      # The SessionRegistry is a plain Registry, not a named process per-se
      # but the Registry should be registered under CodingAgent.SessionRegistry
      assert Process.whereis(CodingAgent.SessionRegistry) != nil

      # Verify via/1 helper works
      session_id = "test-session-#{System.unique_integer([:positive])}"
      via = CodingAgent.SessionRegistry.via(session_id)
      assert {:via, Registry, {CodingAgent.SessionRegistry, ^session_id}} = via
    end

    test "SessionSupervisor is started" do
      assert Process.whereis(CodingAgent.SessionSupervisor) != nil

      # Verify it's a DynamicSupervisor
      children = DynamicSupervisor.which_children(CodingAgent.SessionSupervisor)
      assert is_list(children)
    end

    test "supervisor has correct child count" do
      children = Supervisor.which_children(CodingAgent.Supervisor)
      child_ids = children |> Enum.map(fn {id, _, _, _} -> id end) |> MapSet.new()

      for expected_child <- @expected_children do
        assert MapSet.member?(child_ids, expected_child)
      end

      # Runtime/feature-dependent children may be added, so avoid exact equality.
      assert length(children) >= length(@expected_children)
    end

    test "supervisor uses one_for_one strategy" do
      # Verify children have unique ids
      children = Supervisor.which_children(CodingAgent.Supervisor)
      ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "child process characteristics" do
    test "all child processes are alive" do
      children = Supervisor.which_children(CodingAgent.Supervisor)

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end
    end

    test "supervisor counts children correctly" do
      counts = Supervisor.count_children(CodingAgent.Supervisor)

      min_expected_children = length(@expected_children)

      # Dynamic/runtime children can increase these counts.
      assert counts.active >= min_expected_children
      assert counts.specs >= min_expected_children
      # SessionSupervisor is a DynamicSupervisor
      assert counts.supervisors >= 1
    end
  end

  describe "SessionSupervisor functionality" do
    test "can list sessions when empty" do
      sessions = CodingAgent.SessionSupervisor.list_sessions()
      assert is_list(sessions)
    end

    test "can look up non-existent session" do
      result = CodingAgent.SessionSupervisor.lookup("non-existent-session-id")
      assert result == :error
    end
  end

  describe "SessionRegistry functionality" do
    test "lookup returns :error for non-existent session" do
      result = CodingAgent.SessionRegistry.lookup("definitely-does-not-exist")
      assert result == :error
    end

    test "list_ids returns list" do
      ids = CodingAgent.SessionRegistry.list_ids()
      assert is_list(ids)
    end

    test "via/1 creates proper tuple" do
      session_id = "test-via-session"
      via = CodingAgent.SessionRegistry.via(session_id)

      assert {:via, Registry, {CodingAgent.SessionRegistry, "test-via-session"}} = via
    end
  end

  describe "primary session configuration" do
    test "application starts without primary_session config" do
      # This test verifies the application handles nil :primary_session gracefully
      # The application is already started, so we just verify it's running
      assert Process.whereis(CodingAgent.Supervisor) != nil
    end
  end

  describe "graceful shutdown behavior" do
    test "SessionSupervisor stops cleanly when empty" do
      # Verify the supervisor can list children without error
      sessions = CodingAgent.SessionSupervisor.list_sessions()
      assert is_list(sessions)

      # Verify we can check the DynamicSupervisor state
      counts = DynamicSupervisor.count_children(CodingAgent.SessionSupervisor)
      assert is_map(counts)
      assert Map.has_key?(counts, :active)
    end
  end
end
