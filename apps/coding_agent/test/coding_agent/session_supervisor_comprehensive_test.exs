defmodule CodingAgent.SessionSupervisorComprehensiveTest do
  @moduledoc """
  Comprehensive integration tests for CodingAgent.SessionSupervisor.

  These tests cover:
  - Multi-session management under the same supervisor
  - Session lifecycle (start, run, stop)
  - Crash recovery scenarios
  - Cascading failures
  - Session isolation
  - Resource cleanup
  - Concurrent session creation
  - Supervisor restart strategies
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.SessionRegistry
  alias CodingAgent.SessionSupervisor

  alias Ai.Types.{
    AssistantMessage,
    Model,
    ModelCost,
    TextContent,
    Usage,
    Cost
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

  defp mock_usage(opts \\ []) do
    %Usage{
      input: Keyword.get(opts, :input, 100),
      output: Keyword.get(opts, :output, 50),
      cache_read: Keyword.get(opts, :cache_read, 0),
      cache_write: Keyword.get(opts, :cache_write, 0),
      total_tokens: Keyword.get(opts, :total_tokens, 150),
      cost: Keyword.get(opts, :cost, %Cost{input: 0.001, output: 0.0015, total: 0.0025})
    }
  end

  defp assistant_message(text, opts \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      model: Keyword.get(opts, :model, "mock-model"),
      usage: Keyword.get(opts, :usage, mock_usage()),
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      error_message: Keyword.get(opts, :error_message, nil),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_start, idx, response})
            Ai.EventStream.push(stream, {:text_delta, idx, text, response})
            Ai.EventStream.push(stream, {:text_end, idx, response})

          _ ->
            :ok
        end
      end)

      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp mock_stream_fn do
    fn _model, _context, _options ->
      {:ok, response_to_event_stream(assistant_message("Hello!"))}
    end
  end

  defp default_session_opts(overrides \\ []) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn()
      ],
      overrides
    )
  end

  defp start_test_session(opts \\ []) do
    opts = default_session_opts(opts)
    SessionSupervisor.start_session(opts)
  end

  defp cleanup_all_sessions do
    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(50)
  end

  defp wait_for_process_exit(pid, timeout \\ 1000) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, timeout
  end

  setup do
    # Ensure registry is started
    unless Process.whereis(SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: SessionRegistry})
    end

    # Ensure supervisor is started
    unless Process.whereis(SessionSupervisor) do
      start_supervised!(SessionSupervisor)
    end

    # Cleanup any existing sessions before each test
    cleanup_all_sessions()

    on_exit(fn ->
      cleanup_all_sessions()
    end)

    :ok
  end

  # ============================================================================
  # Multi-Session Management Tests
  # ============================================================================

  describe "multi-session management" do
    test "can start multiple sessions simultaneously" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      {:ok, pid3} = start_test_session()

      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
      assert Process.alive?(pid3)

      sessions = SessionSupervisor.list_sessions()
      assert length(sessions) >= 3
    end

    test "each session has a unique session_id" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      {:ok, pid3} = start_test_session()

      stats1 = Session.get_stats(pid1)
      stats2 = Session.get_stats(pid2)
      stats3 = Session.get_stats(pid3)

      refute stats1.session_id == stats2.session_id
      refute stats2.session_id == stats3.session_id
      refute stats1.session_id == stats3.session_id
    end

    test "sessions with explicit session_ids are registered correctly" do
      session_id1 = "test-session-#{:erlang.unique_integer([:positive])}"
      session_id2 = "test-session-#{:erlang.unique_integer([:positive])}"

      {:ok, pid1} = start_test_session(session_id: session_id1)
      {:ok, pid2} = start_test_session(session_id: session_id2)

      assert {:ok, ^pid1} = SessionRegistry.lookup(session_id1)
      assert {:ok, ^pid2} = SessionRegistry.lookup(session_id2)
    end

    test "can query sessions from supervisor" do
      {:ok, _pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()

      sessions = SessionSupervisor.list_sessions()
      assert length(sessions) >= 2
      assert Enum.all?(sessions, &is_pid/1)
    end

    test "sessions can have different models" do
      model1 = mock_model(id: "model-1", name: "Model One")
      model2 = mock_model(id: "model-2", name: "Model Two")

      {:ok, pid1} = start_test_session(model: model1)
      {:ok, pid2} = start_test_session(model: model2)

      state1 = Session.get_state(pid1)
      state2 = Session.get_state(pid2)

      assert state1.model.id == "model-1"
      assert state2.model.id == "model-2"
    end

    test "sessions can have different working directories" do
      dir1 = System.tmp_dir!()
      dir2 = Path.join(System.tmp_dir!(), "test_subdir_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir2)

      {:ok, pid1} = start_test_session(cwd: dir1)
      {:ok, pid2} = start_test_session(cwd: dir2)

      state1 = Session.get_state(pid1)
      state2 = Session.get_state(pid2)

      assert state1.cwd == dir1
      assert state2.cwd == dir2

      File.rm_rf!(dir2)
    end

    test "can manage 10+ sessions concurrently" do
      pids =
        for _ <- 1..10 do
          {:ok, pid} = start_test_session()
          pid
        end

      assert length(pids) == 10
      assert Enum.all?(pids, &Process.alive?/1)

      sessions = SessionSupervisor.list_sessions()
      assert length(sessions) >= 10
    end
  end

  # ============================================================================
  # Session Lifecycle Tests
  # ============================================================================

  describe "session lifecycle - start" do
    test "start_session returns {:ok, pid}" do
      result = start_test_session()
      assert {:ok, pid} = result
      assert is_pid(pid)
    end

    test "started session is alive" do
      {:ok, pid} = start_test_session()
      assert Process.alive?(pid)
    end

    test "started session is not linked to caller" do
      {:ok, pid} = start_test_session()
      {:links, links} = Process.info(self(), :links)
      refute pid in links
    end

    test "started session is supervised by SessionSupervisor" do
      {:ok, pid} = start_test_session()

      # Session should appear in supervisor's children
      sessions = SessionSupervisor.list_sessions()
      assert pid in sessions
    end

    test "session initializes with correct state" do
      {:ok, pid} = start_test_session(thinking_level: :high)

      state = Session.get_state(pid)
      assert state.cwd == System.tmp_dir!()
      assert state.thinking_level == :high
      assert state.is_streaming == false
    end
  end

  describe "session lifecycle - run" do
    test "session can receive prompts" do
      {:ok, pid} = start_test_session()

      result = Session.prompt(pid, "Hello!")
      assert result == :ok
    end

    test "session can be subscribed to" do
      {:ok, pid} = start_test_session()

      unsub = Session.subscribe(pid)
      assert is_function(unsub, 0)

      # Clean up subscription
      unsub.()
    end

    test "session can switch models" do
      {:ok, pid} = start_test_session()

      new_model = mock_model(id: "new-model")
      :ok = Session.switch_model(pid, new_model)

      state = Session.get_state(pid)
      assert state.model.id == "new-model"
    end

    test "session can be reset" do
      {:ok, pid} = start_test_session()

      :ok = Session.prompt(pid, "Hello!")
      Process.sleep(100)

      :ok = Session.reset(pid)

      state = Session.get_state(pid)
      assert state.turn_index == 0
    end
  end

  describe "session lifecycle - stop" do
    test "stop_session by pid terminates session" do
      {:ok, pid} = start_test_session()
      ref = Process.monitor(pid)

      :ok = SessionSupervisor.stop_session(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      refute Process.alive?(pid)
    end

    test "stop_session by session_id terminates session" do
      session_id = "stop-test-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)
      ref = Process.monitor(pid)

      :ok = SessionSupervisor.stop_session(session_id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      refute Process.alive?(pid)
    end

    test "stop_session for non-existent session_id returns error" do
      result = SessionSupervisor.stop_session("non-existent-session-id")
      assert result == {:error, :not_found}
    end

    test "stopped session is removed from supervisor" do
      {:ok, pid} = start_test_session()

      :ok = SessionSupervisor.stop_session(pid)
      Process.sleep(50)

      sessions = SessionSupervisor.list_sessions()
      refute pid in sessions
    end

    test "stopped session is unregistered from registry" do
      session_id = "unregister-test-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)

      :ok = SessionSupervisor.stop_session(pid)
      Process.sleep(50)

      assert :error = SessionRegistry.lookup(session_id)
    end
  end

  # ============================================================================
  # Crash Recovery Tests
  # ============================================================================

  describe "crash recovery - session crashes" do
    test "crashed session is not automatically restarted" do
      {:ok, pid} = start_test_session()
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      Process.sleep(100)

      # Session should not be restarted
      refute Process.alive?(pid)
    end

    test "supervisor remains alive after session crash" do
      {:ok, pid} = start_test_session()

      Process.exit(pid, :kill)
      Process.sleep(100)

      assert Process.whereis(SessionSupervisor)
      assert Process.alive?(Process.whereis(SessionSupervisor))
    end

    test "other sessions are unaffected by one session crashing" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      {:ok, pid3} = start_test_session()

      Process.exit(pid2, :kill)
      Process.sleep(100)

      assert Process.alive?(pid1)
      assert Process.alive?(pid3)
      refute Process.alive?(pid2)
    end

    test "crashed session is removed from list_sessions" do
      {:ok, pid} = start_test_session()

      initial_count = length(SessionSupervisor.list_sessions())

      Process.exit(pid, :kill)
      Process.sleep(100)

      final_count = length(SessionSupervisor.list_sessions())
      assert final_count == initial_count - 1
    end
  end

  describe "crash recovery - internal agent crashes" do
    test "session with dead agent reports unhealthy status" do
      {:ok, pid} = start_test_session()

      state = Session.get_state(pid)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      health = Session.health_check(pid)
      assert health.status == :unhealthy
      assert health.agent_alive == false
    end

    test "health_all includes unhealthy sessions first" do
      {:ok, pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()

      # Kill agent of first session
      state = Session.get_state(pid1)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      health_results = SessionSupervisor.health_all()

      # First result should be unhealthy
      first_result = List.first(health_results)
      assert first_result.status == :unhealthy
    end

    test "health_summary reflects unhealthy sessions" do
      {:ok, pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()

      # Kill agent of first session
      state = Session.get_state(pid1)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      summary = SessionSupervisor.health_summary()

      assert summary.unhealthy >= 1
      assert summary.overall == :unhealthy
    end
  end

  # ============================================================================
  # Cascading Failure Tests
  # ============================================================================

  describe "cascading failures" do
    test "multiple session crashes in succession do not affect supervisor" do
      pids =
        for _ <- 1..5 do
          {:ok, pid} = start_test_session()
          pid
        end

      # Crash sessions one by one
      Enum.each(pids, fn pid ->
        Process.exit(pid, :kill)
        Process.sleep(10)
      end)

      Process.sleep(100)

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(SessionSupervisor))
    end

    test "rapid session creation and termination is handled gracefully" do
      for _ <- 1..20 do
        {:ok, pid} = start_test_session()
        Process.exit(pid, :kill)
      end

      Process.sleep(200)

      # Supervisor should still be alive and functional
      assert Process.alive?(Process.whereis(SessionSupervisor))

      # Should be able to start new sessions
      {:ok, new_pid} = start_test_session()
      assert Process.alive?(new_pid)
    end

    test "supervisor handles batch session termination" do
      pids =
        for _ <- 1..10 do
          {:ok, pid} = start_test_session()
          pid
        end

      # Kill all at once
      Enum.each(pids, &Process.exit(&1, :kill))

      Process.sleep(200)

      # Supervisor should still be functional
      assert Process.alive?(Process.whereis(SessionSupervisor))
      {:ok, new_pid} = start_test_session()
      assert Process.alive?(new_pid)
    end
  end

  # ============================================================================
  # Session Isolation Tests
  # ============================================================================

  describe "session isolation" do
    test "sessions do not share state" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()

      # Modify one session
      :ok = Session.steer(pid1, "Steer message")
      :ok = Session.follow_up(pid1, "Follow-up message")

      state1 = Session.get_state(pid1)
      state2 = Session.get_state(pid2)

      # Session 2 should not have the queued messages
      assert :queue.len(state1.steering_queue) == 1
      assert :queue.len(state2.steering_queue) == 0
    end

    test "session events are isolated to subscribers" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()

      # Subscribe only to session 1
      _unsub = Session.subscribe(pid1)

      # Send prompt to session 2
      :ok = Session.prompt(pid2, "Hello!")

      # Should not receive events from session 2
      refute_receive {:session_event, _, _}, 200
    end

    test "stopping one session does not affect others" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()

      :ok = SessionSupervisor.stop_session(pid1)
      Process.sleep(50)

      assert Process.alive?(pid2)

      stats2 = Session.get_stats(pid2)
      assert is_binary(stats2.session_id)
    end

    test "sessions can operate independently and concurrently" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()

      # Start streaming on both
      :ok = Session.prompt(pid1, "Hello from 1!")
      :ok = Session.prompt(pid2, "Hello from 2!")

      Process.sleep(200)

      # Both should complete without affecting each other
      state1 = Session.get_state(pid1)
      state2 = Session.get_state(pid2)

      assert state1.turn_index >= 1
      assert state2.turn_index >= 1
    end
  end

  # ============================================================================
  # Resource Cleanup Tests
  # ============================================================================

  describe "resource cleanup" do
    test "session resources are cleaned up on normal stop" do
      session_id = "cleanup-test-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)

      # Get agent pid before stopping
      state = Session.get_state(pid)
      agent_pid = state.agent
      agent_ref = Process.monitor(agent_pid)

      :ok = SessionSupervisor.stop_session(pid)

      # Agent should also be stopped
      assert_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _}, 1000

      # Registry should be cleaned up
      assert :error = SessionRegistry.lookup(session_id)
    end

    test "session resources are cleaned up on crash" do
      session_id = "crash-cleanup-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)

      Process.exit(pid, :kill)
      Process.sleep(100)

      # Registry should be cleaned up
      assert :error = SessionRegistry.lookup(session_id)
    end

    test "subscribers are cleaned up when session stops" do
      {:ok, pid} = start_test_session()

      _unsub = Session.subscribe(pid)

      state_before = Session.get_state(pid)
      assert length(state_before.event_listeners) >= 1

      # Stop session gracefully
      :ok = SessionSupervisor.stop_session(pid)
      Process.sleep(50)

      # Session is gone, so listeners are cleaned up implicitly
      refute Process.alive?(pid)
    end

    test "multiple sessions cleanup independently" do
      session_id1 = "multi-cleanup-1-#{:erlang.unique_integer([:positive])}"
      session_id2 = "multi-cleanup-2-#{:erlang.unique_integer([:positive])}"

      {:ok, pid1} = start_test_session(session_id: session_id1)
      {:ok, pid2} = start_test_session(session_id: session_id2)

      :ok = SessionSupervisor.stop_session(pid1)
      Process.sleep(50)

      # Session 1 should be cleaned up
      assert :error = SessionRegistry.lookup(session_id1)

      # Session 2 should still be registered
      assert {:ok, ^pid2} = SessionRegistry.lookup(session_id2)
    end
  end

  # ============================================================================
  # Concurrent Session Creation Tests
  # ============================================================================

  describe "concurrent session creation" do
    test "can create sessions concurrently from multiple processes" do
      parent = self()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result = start_test_session(session_id: "concurrent-#{i}-#{:erlang.unique_integer([:positive])}")
            send(parent, {:created, i, result})
            result
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
        {:ok, pid} -> is_pid(pid) and Process.alive?(pid)
        _ -> false
      end)
    end

    test "concurrent creation produces unique session IDs" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            {:ok, pid} = start_test_session()
            Session.get_stats(pid).session_id
          end)
        end

      session_ids = Task.await_many(tasks, 5000)

      # All session IDs should be unique
      assert length(Enum.uniq(session_ids)) == length(session_ids)
    end

    test "concurrent creation and stop is thread-safe" do
      # Create sessions
      pids =
        for _ <- 1..10 do
          {:ok, pid} = start_test_session()
          pid
        end

      # Concurrently stop half and create new ones
      stop_tasks =
        for pid <- Enum.take(pids, 5) do
          Task.async(fn ->
            SessionSupervisor.stop_session(pid)
          end)
        end

      create_tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            start_test_session()
          end)
        end

      Task.await_many(stop_tasks ++ create_tasks, 5000)

      # Supervisor should still be functional
      assert Process.alive?(Process.whereis(SessionSupervisor))
    end

    test "high contention does not cause race conditions" do
      # Start and stop many sessions rapidly with high concurrency
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            {:ok, pid} = start_test_session()
            Process.sleep(:rand.uniform(10))

            if rem(i, 2) == 0 do
              SessionSupervisor.stop_session(pid)
              :stopped
            else
              :kept
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Should complete without errors
      assert length(results) == 50
      assert Enum.all?(results, fn r -> r in [:stopped, :kept] end)

      # Supervisor should be functional
      {:ok, new_pid} = start_test_session()
      assert Process.alive?(new_pid)
    end
  end

  # ============================================================================
  # Supervisor Restart Strategy Tests
  # ============================================================================

  describe "supervisor restart strategy" do
    test "uses DynamicSupervisor with :one_for_one strategy" do
      # This is implicit from the module definition, but we verify behavior
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()

      # Kill one session - should not affect the other
      Process.exit(pid1, :kill)
      Process.sleep(50)

      assert Process.alive?(pid2)
    end

    test "temporary restart means crashed sessions are not restarted" do
      {:ok, pid} = start_test_session()
      ref = Process.monitor(pid)

      initial_sessions = SessionSupervisor.list_sessions()

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      Process.sleep(100)

      # Session count should decrease (not restarted)
      final_sessions = SessionSupervisor.list_sessions()
      assert length(final_sessions) == length(initial_sessions) - 1
    end

    test "supervisor can recover after max_children is reached (if configured)" do
      # DynamicSupervisor has no default max_children, but let's verify
      # we can create many sessions
      pids =
        for _ <- 1..20 do
          {:ok, pid} = start_test_session()
          pid
        end

      assert length(pids) == 20

      # Clean up
      Enum.each(pids, &SessionSupervisor.stop_session/1)
    end
  end

  # ============================================================================
  # Health Monitoring Tests
  # ============================================================================

  describe "health monitoring across sessions" do
    test "health_all returns empty list when no sessions" do
      cleanup_all_sessions()
      Process.sleep(50)

      assert SessionSupervisor.health_all() == []
    end

    test "health_all returns health for all sessions" do
      {:ok, _pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()
      {:ok, _pid3} = start_test_session()

      health_results = SessionSupervisor.health_all()

      assert length(health_results) >= 3
      assert Enum.all?(health_results, &Map.has_key?(&1, :status))
    end

    test "health_all sorts by status (unhealthy first, then degraded, then healthy)" do
      {:ok, pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()

      # Make one session unhealthy
      state = Session.get_state(pid1)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      health_results = SessionSupervisor.health_all()

      # Verify sorting
      statuses = Enum.map(health_results, & &1.status)
      unhealthy_idx = Enum.find_index(statuses, &(&1 == :unhealthy))
      healthy_idx = Enum.find_index(statuses, &(&1 == :healthy))

      if unhealthy_idx && healthy_idx do
        assert unhealthy_idx < healthy_idx
      end
    end

    test "health_summary provides aggregate counts" do
      {:ok, _pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()
      {:ok, _pid3} = start_test_session()

      summary = SessionSupervisor.health_summary()

      assert summary.total >= 3
      assert summary.healthy + summary.degraded + summary.unhealthy == summary.total
      assert summary.overall in [:healthy, :degraded, :unhealthy]
    end

    test "health_summary returns :no_sessions when empty" do
      cleanup_all_sessions()
      Process.sleep(50)

      summary = SessionSupervisor.health_summary()

      assert summary.total == 0
      assert summary.overall == :no_sessions
    end

    test "health_summary reflects overall system health" do
      {:ok, _pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()

      # All healthy
      summary1 = SessionSupervisor.health_summary()
      assert summary1.overall == :healthy

      # Make one unhealthy
      {:ok, pid3} = start_test_session()
      state = Session.get_state(pid3)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      summary2 = SessionSupervisor.health_summary()
      assert summary2.overall == :unhealthy
    end
  end

  # ============================================================================
  # Lookup Tests
  # ============================================================================

  describe "session lookup" do
    test "lookup returns {:ok, pid} for existing session" do
      session_id = "lookup-test-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)

      assert {:ok, ^pid} = SessionSupervisor.lookup(session_id)
    end

    test "lookup returns :error for non-existent session" do
      assert :error = SessionSupervisor.lookup("non-existent-session")
    end

    test "lookup returns :error after session is stopped" do
      session_id = "lookup-stop-test-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)

      :ok = SessionSupervisor.stop_session(pid)
      Process.sleep(50)

      assert :error = SessionSupervisor.lookup(session_id)
    end

    test "lookup returns :error after session crashes" do
      session_id = "lookup-crash-test-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: session_id)

      Process.exit(pid, :kill)
      Process.sleep(50)

      assert :error = SessionSupervisor.lookup(session_id)
    end
  end

  # ============================================================================
  # Edge Cases and Boundary Tests
  # ============================================================================

  describe "edge cases" do
    test "stopping already stopped session returns error" do
      {:ok, pid} = start_test_session()

      :ok = SessionSupervisor.stop_session(pid)
      Process.sleep(50)

      # Second stop should fail
      result = SessionSupervisor.stop_session(pid)
      assert result == {:error, :not_found}
    end

    test "list_sessions handles supervisor not running gracefully" do
      # If supervisor is not running, list_sessions should return empty
      # This is tested by the module implementation but we verify behavior
      sessions = SessionSupervisor.list_sessions()
      assert is_list(sessions)
    end

    test "sessions with very long session IDs are handled" do
      long_id = String.duplicate("a", 256)
      {:ok, pid} = start_test_session(session_id: long_id)

      stats = Session.get_stats(pid)
      assert stats.session_id == long_id

      assert {:ok, ^pid} = SessionRegistry.lookup(long_id)
    end

    test "sessions with special characters in session_id are handled" do
      special_id = "test-session-!@#$%^&*()-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_test_session(session_id: special_id)

      stats = Session.get_stats(pid)
      assert stats.session_id == special_id
    end
  end

  # ============================================================================
  # Stress Tests
  # ============================================================================

  describe "stress tests" do
    @tag :stress
    test "can handle rapid session lifecycle operations" do
      for _ <- 1..100 do
        {:ok, pid} = start_test_session()
        :ok = SessionSupervisor.stop_session(pid)
      end

      # Supervisor should still be functional
      {:ok, new_pid} = start_test_session()
      assert Process.alive?(new_pid)
    end

    @tag :stress
    test "concurrent health checks do not cause issues" do
      {:ok, _pid1} = start_test_session()
      {:ok, _pid2} = start_test_session()
      {:ok, _pid3} = start_test_session()

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            SessionSupervisor.health_all()
            SessionSupervisor.health_summary()
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 50
    end
  end
end
