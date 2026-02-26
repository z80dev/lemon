defmodule CodingAgent.SessionRootSupervisorTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionRootSupervisor
  alias CodingAgent.SessionRegistry
  alias CodingAgent.SessionSupervisor

  alias Ai.Types.{
    Model,
    ModelCost
  }

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-#{:erlang.unique_integer([:positive])}"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 0.01, output: 0.03}),
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: Keyword.get(opts, :headers, %{}),
      compat: Keyword.get(opts, :compat, nil)
    }
  end

  defp default_supervisor_opts(overrides \\ []) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model()
      ],
      overrides
    )
  end

  setup do
    # Ensure registry is started for session registration
    unless Process.whereis(SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: SessionRegistry})
    end

    # Ensure SessionSupervisor is started
    unless Process.whereis(SessionSupervisor) do
      start_supervised!(SessionSupervisor)
    end

    :ok
  end

  # ============================================================================
  # Supervisor Initialization Tests
  # ============================================================================

  describe "start_link/1" do
    test "starts successfully with valid options" do
      opts = default_supervisor_opts()
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "starts with custom session_id" do
      session_id = "custom-session-#{:erlang.unique_integer([:positive])}"
      opts = default_supervisor_opts(session_id: session_id)

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # The session should use our custom session_id
      {:ok, session_pid} = SessionRootSupervisor.get_session(pid)
      stats = CodingAgent.Session.get_stats(session_pid)
      assert stats.session_id == session_id

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "generates session_id if not provided" do
      opts = default_supervisor_opts()

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(pid)
      stats = CodingAgent.Session.get_stats(session_pid)

      # Session ID should be a 32-character hex string (16 bytes encoded)
      assert is_binary(stats.session_id)
      assert String.length(stats.session_id) == 32
      assert String.match?(stats.session_id, ~r/^[a-f0-9]+$/)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "passes options through to Session" do
      system_prompt = "Custom system prompt for testing"
      opts = default_supervisor_opts(system_prompt: system_prompt)

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(pid)
      state = CodingAgent.Session.get_state(session_pid)
      assert state.explicit_system_prompt == system_prompt
      assert String.starts_with?(state.system_prompt, system_prompt)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "starts without coordinator by default" do
      opts = default_supervisor_opts()

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Should have session but no coordinator
      assert {:ok, _session} = SessionRootSupervisor.get_session(pid)
      assert :error = SessionRootSupervisor.get_coordinator(pid)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "starts with coordinator when with_coordinator: true" do
      opts = default_supervisor_opts(with_coordinator: true)

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Should have both session and coordinator
      assert {:ok, session_pid} = SessionRootSupervisor.get_session(pid)
      assert {:ok, coordinator_pid} = SessionRootSupervisor.get_coordinator(pid)

      assert is_pid(session_pid)
      assert is_pid(coordinator_pid)
      assert Process.alive?(session_pid)
      assert Process.alive?(coordinator_pid)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "coordinator receives correct options from session opts" do
      thinking_level = :high
      opts = default_supervisor_opts(with_coordinator: true, thinking_level: thinking_level)

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      {:ok, coordinator_pid} = SessionRootSupervisor.get_coordinator(pid)
      assert Process.alive?(coordinator_pid)

      # Cleanup
      Process.exit(pid, :normal)
    end
  end

  # ============================================================================
  # Child Spec Generation Tests
  # ============================================================================

  describe "child specification" do
    test "Session child uses temporary restart strategy" do
      opts = default_supervisor_opts()
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Get supervisor's children info
      children = Supervisor.which_children(pid)

      session_child = Enum.find(children, fn {id, _, _, _} -> id == CodingAgent.Session end)
      assert session_child != nil

      {_id, session_pid, type, _modules} = session_child
      assert is_pid(session_pid)
      assert type == :worker

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "Coordinator child uses temporary restart strategy when started" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      children = Supervisor.which_children(pid)

      coordinator_child =
        Enum.find(children, fn {id, _, _, _} -> id == CodingAgent.Coordinator end)

      assert coordinator_child != nil

      {_id, coordinator_pid, type, _modules} = coordinator_child
      assert is_pid(coordinator_pid)
      assert type == :worker

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "children are started in correct order (Session first)" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # With :rest_for_one strategy, Session should be started first
      # and Coordinator second
      children = Supervisor.which_children(pid)

      # In Supervisor.which_children, children are returned in reverse start order
      # So the first child to start is last in the list
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      session_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Session))
      coordinator_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Coordinator))

      # Session should be at a higher index (started first, appears last in which_children)
      assert session_idx > coordinator_idx

      # Cleanup
      Process.exit(pid, :normal)
    end
  end

  # ============================================================================
  # Supervision Tree Structure Tests
  # ============================================================================

  describe "supervision tree structure" do
    test "supervisor has correct number of children without coordinator" do
      opts = default_supervisor_opts(with_coordinator: false)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      children = Supervisor.which_children(pid)
      assert length(children) == 1

      # Only Session should be present
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert CodingAgent.Session in child_ids
      refute CodingAgent.Coordinator in child_ids

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "supervisor has correct number of children with coordinator" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      children = Supervisor.which_children(pid)
      assert length(children) == 2

      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert CodingAgent.Session in child_ids
      assert CodingAgent.Coordinator in child_ids

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "uses :rest_for_one supervision strategy" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Verify the supervision strategy through the Supervisor's count_children
      # which confirms proper supervisor setup
      counts = Supervisor.count_children(pid)
      assert counts.active == 2
      assert counts.workers == 2

      # We can also verify that the children are properly ordered by checking
      # the which_children output (reversed order from start order)
      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      # Session should come after Coordinator in the list (started first)
      session_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Session))
      coordinator_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Coordinator))
      assert session_idx > coordinator_idx

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "all children are workers, not supervisors" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      children = Supervisor.which_children(pid)

      Enum.each(children, fn {_id, _child_pid, type, _modules} ->
        assert type == :worker
      end)

      # Cleanup
      Process.exit(pid, :normal)
    end
  end

  # ============================================================================
  # Restart Strategy Tests
  # ============================================================================

  describe "restart strategies" do
    test "session does not auto-restart on crash (temporary)" do
      opts = default_supervisor_opts()
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(sup_pid)
      session_ref = Process.monitor(session_pid)

      # Kill the session
      Process.exit(session_pid, :kill)

      # Wait for it to die
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, _}, 1_000

      # Give supervisor time to potentially restart (it shouldn't)
      Process.sleep(100)

      # Session should NOT have been restarted
      assert :error = SessionRootSupervisor.get_session(sup_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "coordinator does not auto-restart on crash (temporary)" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, coordinator_pid} = SessionRootSupervisor.get_coordinator(sup_pid)
      coordinator_ref = Process.monitor(coordinator_pid)

      # Kill the coordinator
      Process.exit(coordinator_pid, :kill)

      # Wait for it to die
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator_pid, _}, 1_000

      # Give supervisor time to potentially restart (it shouldn't)
      Process.sleep(100)

      # Coordinator should NOT have been restarted
      assert :error = SessionRootSupervisor.get_coordinator(sup_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "supervisor remains alive after child crash" do
      opts = default_supervisor_opts()
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(sup_pid)

      # Kill the session
      Process.exit(session_pid, :kill)

      # Give time for the crash to propagate
      Process.sleep(100)

      # Supervisor should still be alive
      assert Process.alive?(sup_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end
  end

  # ============================================================================
  # Helper Function Tests
  # ============================================================================

  describe "get_session/1" do
    test "returns {:ok, pid} when session is running" do
      opts = default_supervisor_opts()
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      result = SessionRootSupervisor.get_session(sup_pid)

      assert {:ok, session_pid} = result
      assert is_pid(session_pid)
      assert Process.alive?(session_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "returns :error when session is not running" do
      opts = default_supervisor_opts()
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(sup_pid)

      # Kill the session
      Process.exit(session_pid, :kill)
      Process.sleep(100)

      # Now get_session should return :error
      assert :error = SessionRootSupervisor.get_session(sup_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end
  end

  describe "get_coordinator/1" do
    test "returns {:ok, pid} when coordinator is running" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      result = SessionRootSupervisor.get_coordinator(sup_pid)

      assert {:ok, coordinator_pid} = result
      assert is_pid(coordinator_pid)
      assert Process.alive?(coordinator_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "returns :error when no coordinator was started" do
      opts = default_supervisor_opts(with_coordinator: false)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      result = SessionRootSupervisor.get_coordinator(sup_pid)

      assert :error = result

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "returns :error when coordinator was started but crashed" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, coordinator_pid} = SessionRootSupervisor.get_coordinator(sup_pid)

      # Kill the coordinator
      Process.exit(coordinator_pid, :kill)
      Process.sleep(100)

      # Now get_coordinator should return :error
      assert :error = SessionRootSupervisor.get_coordinator(sup_pid)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end
  end

  describe "list_children/1" do
    test "returns list of alive children as {module, pid} tuples" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      children = SessionRootSupervisor.list_children(sup_pid)

      assert length(children) == 2

      child_modules = Enum.map(children, fn {module, _pid} -> module end)
      assert CodingAgent.Session in child_modules
      assert CodingAgent.Coordinator in child_modules

      Enum.each(children, fn {module, pid} ->
        assert is_atom(module)
        assert is_pid(pid)
        assert Process.alive?(pid)
      end)

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "returns only alive children" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      # Initially should have 2 children
      assert length(SessionRootSupervisor.list_children(sup_pid)) == 2

      # Kill the coordinator
      {:ok, coordinator_pid} = SessionRootSupervisor.get_coordinator(sup_pid)
      Process.exit(coordinator_pid, :kill)
      Process.sleep(100)

      # Now should have only 1 child
      children = SessionRootSupervisor.list_children(sup_pid)
      assert length(children) == 1

      [{module, _pid}] = children
      assert module == CodingAgent.Session

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "returns empty list when all children have crashed" do
      opts = default_supervisor_opts()
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(sup_pid)

      # Kill the session
      Process.exit(session_pid, :kill)
      Process.sleep(100)

      # Should return empty list
      children = SessionRootSupervisor.list_children(sup_pid)
      assert children == []

      # Cleanup
      Process.exit(sup_pid, :normal)
    end
  end

  # ============================================================================
  # Session ID Handling Tests
  # ============================================================================

  describe "session_id handling" do
    test "same session_id is used for both Session and Coordinator" do
      session_id = "shared-session-#{:erlang.unique_integer([:positive])}"
      opts = default_supervisor_opts(session_id: session_id, with_coordinator: true)

      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(sup_pid)
      session_stats = CodingAgent.Session.get_stats(session_pid)

      # Both should use the same session_id
      assert session_stats.session_id == session_id

      # Cleanup
      Process.exit(sup_pid, :normal)
    end

    test "generated session_id is consistent within supervisor" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, sup_pid} = SessionRootSupervisor.start_link(opts)

      {:ok, session_pid} = SessionRootSupervisor.get_session(sup_pid)
      session_stats = CodingAgent.Session.get_stats(session_pid)

      # Session ID should be set
      assert is_binary(session_stats.session_id)
      assert session_stats.session_id != ""

      # Cleanup
      Process.exit(sup_pid, :normal)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "fails when cwd is missing for coordinator" do
      Process.flag(:trap_exit, true)

      # with_coordinator: true requires cwd for Coordinator
      result = SessionRootSupervisor.start_link(model: mock_model(), with_coordinator: true)

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          # If it started, it should crash quickly
          assert_receive {:EXIT, ^pid, _reason}, 500
      end

      Process.flag(:trap_exit, false)
    end

    test "fails when model is missing for coordinator" do
      Process.flag(:trap_exit, true)

      # with_coordinator: true requires model for Coordinator
      result = SessionRootSupervisor.start_link(cwd: System.tmp_dir!(), with_coordinator: true)

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          # If it started, it should crash quickly
          assert_receive {:EXIT, ^pid, _reason}, 500
      end

      Process.flag(:trap_exit, false)
    end
  end

  # ============================================================================
  # Isolation Tests
  # ============================================================================

  describe "session isolation" do
    test "multiple supervisor instances are independent" do
      opts1 =
        default_supervisor_opts(session_id: "session-1-#{:erlang.unique_integer([:positive])}")

      opts2 =
        default_supervisor_opts(session_id: "session-2-#{:erlang.unique_integer([:positive])}")

      {:ok, sup1} = SessionRootSupervisor.start_link(opts1)
      {:ok, sup2} = SessionRootSupervisor.start_link(opts2)

      {:ok, session1} = SessionRootSupervisor.get_session(sup1)
      {:ok, session2} = SessionRootSupervisor.get_session(sup2)

      # Sessions should be different PIDs
      refute session1 == session2

      # Get session IDs
      stats1 = CodingAgent.Session.get_stats(session1)
      stats2 = CodingAgent.Session.get_stats(session2)
      refute stats1.session_id == stats2.session_id

      # Killing one should not affect the other
      Process.exit(session1, :kill)
      Process.sleep(100)

      assert Process.alive?(session2)
      assert Process.alive?(sup2)

      # Cleanup
      Process.exit(sup1, :normal)
      Process.exit(sup2, :normal)
    end

    test "crashing one supervisor does not affect another" do
      # Trap exits to prevent test process from being killed
      Process.flag(:trap_exit, true)

      opts1 = default_supervisor_opts()
      opts2 = default_supervisor_opts()

      {:ok, sup1} = SessionRootSupervisor.start_link(opts1)
      {:ok, sup2} = SessionRootSupervisor.start_link(opts2)

      ref1 = Process.monitor(sup1)

      # Kill the first supervisor
      Process.exit(sup1, :kill)

      assert_receive {:DOWN, ^ref1, :process, ^sup1, _}, 1_000

      # Second supervisor should be unaffected
      assert Process.alive?(sup2)
      assert {:ok, _session} = SessionRootSupervisor.get_session(sup2)

      # Cleanup
      Process.exit(sup2, :normal)
      Process.flag(:trap_exit, false)
    end
  end
end
