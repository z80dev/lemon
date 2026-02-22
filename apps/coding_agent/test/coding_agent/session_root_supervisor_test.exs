defmodule CodingAgent.SessionRootSupervisorTest do
  @moduledoc """
  Tests for the SessionRootSupervisor module.

  The SessionRootSupervisor is a per-session supervisor that manages:
  - CodingAgent.Session - The main session GenServer
  - Optional CodingAgent.Coordinator - For managing subagents

  These tests verify the supervisor's initialization, child management,
  restart strategies, and helper functions.
  """

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
  # start_link/1 Tests
  # ============================================================================

  describe "start_link/1" do
    test "starts the supervisor correctly with valid options" do
      opts = default_supervisor_opts()
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      assert is_pid(pid)
      assert Process.alive?(pid)

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
  end

  # ============================================================================
  # init/1 Tests - Child Specification
  # ============================================================================

  describe "init/1" do
    test "creates proper child specification for Session" do
      opts = default_supervisor_opts()
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      children = Supervisor.which_children(pid)

      session_child = Enum.find(children, fn {id, _, _, _} -> id == CodingAgent.Session end)
      assert session_child != nil

      {_id, session_pid, type, _modules} = session_child
      assert is_pid(session_pid)
      assert type == :worker

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "creates proper child specification for Coordinator when enabled" do
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

    test "children have :temporary restart policy" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Get the child specifications to verify restart policy
      # We verify by checking that crashed children don't restart
      {:ok, session_pid} = SessionRootSupervisor.get_session(pid)
      session_ref = Process.monitor(session_pid)

      # Kill the session
      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, _}, 1_000

      # Give supervisor time to potentially restart (it shouldn't with :temporary)
      Process.sleep(100)

      # Session should NOT have been restarted
      assert :error = SessionRootSupervisor.get_session(pid)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "uses :rest_for_one supervision strategy" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Verify the supervision strategy through child ordering
      # With :rest_for_one, children are started in order and stopped in reverse
      counts = Supervisor.count_children(pid)
      assert counts.active == 2
      assert counts.workers == 2

      # Verify children are properly ordered
      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      # Session should come after Coordinator in which_children (started first)
      session_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Session))
      coordinator_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Coordinator))
      assert session_idx > coordinator_idx

      # Cleanup
      Process.exit(pid, :normal)
    end
  end

  # ============================================================================
  # get_session/1 Tests
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

  # ============================================================================
  # get_coordinator/1 Tests
  # ============================================================================

  describe "get_coordinator/1" do
    test "returns {:ok, pid} when coordinator is present and running" do
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

  # ============================================================================
  # list_children/1 Tests
  # ============================================================================

  describe "list_children/1" do
    test "returns all children as {module, pid} tuples" do
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
  # Supervision Strategy Tests
  # ============================================================================

  describe "supervision strategy" do
    test "supervisor uses :rest_for_one strategy" do
      opts = default_supervisor_opts(with_coordinator: true)
      {:ok, pid} = SessionRootSupervisor.start_link(opts)

      # Verify through child ordering - with :rest_for_one, order matters
      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      # Session should be started first (appears last in which_children)
      session_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Session))
      coordinator_idx = Enum.find_index(child_ids, &(&1 == CodingAgent.Coordinator))

      assert session_idx > coordinator_idx,
             "Session should be started before Coordinator for :rest_for_one to work correctly"

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "children have :temporary restart policy - session does not auto-restart" do
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

    test "children have :temporary restart policy - coordinator does not auto-restart" do
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
  # Session ID Generation Tests
  # ============================================================================

  describe "session_id handling" do
    test "uses provided session_id" do
      session_id = "custom-session-#{:erlang.unique_integer([:positive])}"
      opts = default_supervisor_opts(session_id: session_id)

      {:ok, pid} = SessionRootSupervisor.start_link(opts)

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
  end
end
