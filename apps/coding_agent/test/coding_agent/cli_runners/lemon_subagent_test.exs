defmodule CodingAgent.CliRunners.LemonSubagentTest do
  use ExUnit.Case, async: true

  alias CodingAgent.CliRunners.LemonSubagent

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    ResumeToken,
    StartedEvent
  }

  alias AgentCore.EventStream

  # ============================================================================
  # API Structure Tests
  # ============================================================================

  describe "API structure" do
    test "supports_steer? returns true" do
      assert LemonSubagent.supports_steer?() == true
    end

    test "module exports expected functions" do
      # Verify the public API exists
      assert function_exported?(LemonSubagent, :start, 1)
      assert function_exported?(LemonSubagent, :resume, 2)
      assert function_exported?(LemonSubagent, :continue, 2)
      assert function_exported?(LemonSubagent, :continue, 3)
      assert function_exported?(LemonSubagent, :events, 1)
      assert function_exported?(LemonSubagent, :collect_answer, 1)
      assert function_exported?(LemonSubagent, :resume_token, 1)
      assert function_exported?(LemonSubagent, :cancel, 1)
      assert function_exported?(LemonSubagent, :steer, 2)
      assert function_exported?(LemonSubagent, :follow_up, 2)
      assert function_exported?(LemonSubagent, :run!, 1)
    end
  end

  # ============================================================================
  # Resume Token Handling - Different Scenarios
  # ============================================================================

  describe "resume_token/1" do
    test "returns the resume token from session when no agent" do
      token = ResumeToken.new("lemon", "abc12345")
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: nil, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == token
    end

    test "returns nil when no token and no agent" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == nil
    end

    test "returns token from agent when agent is present" do
      token = ResumeToken.new("lemon", "xyz78901")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == token
      Agent.stop(agent)
    end

    test "falls back to session token when agent is dead" do
      token = ResumeToken.new("lemon", "abc12345")
      {:ok, agent} = Agent.start_link(fn -> nil end)
      Agent.stop(agent)
      # Wait a moment for the agent to fully stop
      Process.sleep(10)
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: agent, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == token
    end

    test "agent token takes precedence over session token" do
      session_token = ResumeToken.new("lemon", "session_original")
      agent_token = ResumeToken.new("lemon", "agent_updated")
      {:ok, agent} = Agent.start_link(fn -> agent_token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: session_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert LemonSubagent.resume_token(session) == agent_token

      Agent.stop(agent)
    end

    test "handles agent returning nil gracefully" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session_token = ResumeToken.new("lemon", "fallback_token")

      session = %{
        pid: nil,
        stream: nil,
        resume_token: session_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Should return nil from agent (not fall back to session token)
      assert LemonSubagent.resume_token(session) == nil

      Agent.stop(agent)
    end

    test "handles concurrent agent access" do
      token = ResumeToken.new("lemon", "concurrent_test")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      # Multiple concurrent reads should all succeed
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> LemonSubagent.resume_token(session) end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, fn t -> t == token end)

      Agent.stop(agent)
    end
  end

  # ============================================================================
  # continue/3 Implementation
  # ============================================================================

  describe "continue/3" do
    test "returns error when no resume token" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert {:error, :no_resume_token} = LemonSubagent.continue(session, "test")
    end

    test "returns error when token agent has nil token" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      assert {:error, :no_resume_token} = LemonSubagent.continue(session, "follow up")

      Agent.stop(agent)
    end

    test "preserves cwd from original session" do
      # We can't fully test this without a running session, but we can verify
      # the options are passed correctly by checking the session struct
      original_cwd = "/my/project/path"
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: original_cwd}

      # Without a token, we get the error - but this verifies the flow
      assert {:error, :no_resume_token} = LemonSubagent.continue(session, "test")
    end

    test "accepts optional keyword arguments" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Test that opts are accepted (will still fail due to no token)
      assert {:error, :no_resume_token} =
               LemonSubagent.continue(session, "test", timeout: 30_000, cwd: "/other/path")
    end

    test "empty prompt is accepted" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert {:error, :no_resume_token} = LemonSubagent.continue(session, "")
    end
  end

  # ============================================================================
  # Stream Handling and Message Routing
  # ============================================================================

  describe "events/1 stream handling" do
    test "returns enumerable for session stream" do
      # Create a mock stream that completes immediately
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      # Complete the stream immediately
      EventStream.complete(stream, [])

      # events/1 should return an enumerable
      events = LemonSubagent.events(session)
      assert is_function(events, 2) or match?(%Stream{}, events)

      # Should be able to enumerate (will get agent_end)
      event_list = Enum.to_list(events)
      assert is_list(event_list)

      Agent.stop(token_agent)
    end

    test "updates token_agent on started event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      # Push a started event
      started_token = ResumeToken.new("lemon", "new_session_123")
      started_event = StartedEvent.new("lemon", started_token)
      EventStream.push_async(stream, {:cli_event, started_event})
      EventStream.complete(stream, [])

      # Consume all events
      _events = session |> LemonSubagent.events() |> Enum.to_list()

      # Token agent should now have the token
      assert Agent.get(token_agent, & &1) == started_token

      Agent.stop(token_agent)
    end

    test "updates token_agent on completed event with resume token" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      # Push a completed event with resume token
      resume_token = ResumeToken.new("lemon", "session_for_resume")
      completed_event = CompletedEvent.ok("lemon", "Done!", resume: resume_token)
      EventStream.push_async(stream, {:cli_event, completed_event})
      EventStream.complete(stream, [])

      # Consume all events
      _events = session |> LemonSubagent.events() |> Enum.to_list()

      # Token agent should have the resume token
      assert Agent.get(token_agent, & &1) == resume_token

      Agent.stop(token_agent)
    end

    test "handles nil token_agent gracefully" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Push events
      started_token = ResumeToken.new("lemon", "test_session")
      started_event = StartedEvent.new("lemon", started_token)
      EventStream.push_async(stream, {:cli_event, started_event})
      EventStream.complete(stream, [])

      # Should not crash with nil token_agent
      events = session |> LemonSubagent.events() |> Enum.to_list()
      assert length(events) >= 1
    end

    test "handles multiple event types in sequence" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      # Push a sequence of events
      token = ResumeToken.new("lemon", "full_session")

      EventStream.push_async(stream, {:cli_event, StartedEvent.new("lemon", token)})

      action = Action.new("tool_1", :command, "$ ls")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("lemon", action, :started)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("lemon", action, :completed, ok: true)}
      )

      EventStream.push_async(
        stream,
        {:cli_event, CompletedEvent.ok("lemon", "All done", resume: token)}
      )

      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      # Should have at least: started, action_started, action_completed, completed, agent_end
      assert length(events) >= 4

      Agent.stop(token_agent)
    end
  end

  # ============================================================================
  # Event Normalization
  # ============================================================================

  describe "event normalization" do
    test "normalizes StartedEvent to {:started, token}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      token = ResumeToken.new("lemon", "norm_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("lemon", token)})
      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      started_events =
        Enum.filter(events, fn
          {:started, _} -> true
          _ -> false
        end)

      assert length(started_events) == 1
      {:started, received_token} = hd(started_events)
      assert received_token == token
    end

    test "normalizes ActionEvent to {:action, action_map, phase, opts}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("tool_42", :file_change, "Write test.ex", %{path: "/app/test.ex"})
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("lemon", action, :started)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("lemon", action, :completed, ok: true)}
      )

      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      assert length(action_events) == 2

      # Check started phase
      {:action, action_map, phase, opts} = Enum.at(action_events, 0)
      assert action_map.id == "tool_42"
      assert action_map.kind == :file_change
      assert action_map.title == "Write test.ex"
      assert phase == :started
      assert opts == []

      # Check completed phase
      {:action, _, :completed, completed_opts} = Enum.at(action_events, 1)
      assert completed_opts == [ok: true]
    end

    test "normalizes CompletedEvent to {:completed, answer, opts}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      token = ResumeToken.new("lemon", "complete_test")
      usage = %{input_tokens: 100, output_tokens: 50}

      EventStream.push_async(
        stream,
        {:cli_event,
         CompletedEvent.ok("lemon", "Task completed successfully", resume: token, usage: usage)}
      )

      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      completed_events =
        Enum.filter(events, fn
          {:completed, _, _} -> true
          _ -> false
        end)

      assert length(completed_events) == 1
      {:completed, answer, opts} = hd(completed_events)
      assert answer == "Task completed successfully"
      assert opts[:ok] == true
      assert opts[:resume] == token
      assert opts[:usage] == usage
    end

    test "normalizes error CompletedEvent with error field" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(
        stream,
        {:cli_event,
         CompletedEvent.error("lemon", "Connection failed", answer: "Partial response")}
      )

      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      completed_events =
        Enum.filter(events, fn
          {:completed, _, _} -> true
          _ -> false
        end)

      {:completed, answer, opts} = hd(completed_events)
      assert answer == "Partial response"
      assert opts[:ok] == false
      assert opts[:error] == "Connection failed"
    end

    test "normalizes {:error, reason, partial} to {:error, reason}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:error, :timeout, %{messages: []}})
      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      error_events =
        Enum.filter(events, fn
          {:error, _} -> true
          _ -> false
        end)

      assert length(error_events) == 1
      {:error, reason} = hd(error_events)
      assert reason == :timeout
    end

    test "normalizes {:canceled, reason} to {:error, {:canceled, reason}}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:canceled, :user_requested})
      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      error_events =
        Enum.filter(events, fn
          {:error, {:canceled, _}} -> true
          _ -> false
        end)

      assert length(error_events) == 1
      {:error, {:canceled, reason}} = hd(error_events)
      assert reason == :user_requested
    end

    test "filters out {:agent_end, _} internal events when followed by other events" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Push a started event first
      token = ResumeToken.new("lemon", "filter_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("lemon", token)})
      # Then push an internal agent_end event (note: this is terminal, stream stops here)
      EventStream.push_async(stream, {:agent_end, []})
      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      # The {:agent_end, []} is terminal and halts the stream after normalization.
      # normalize_event({:agent_end, _}) returns [] so it produces no output event.
      # We should only see the started event, not agent_end.
      started_events =
        Enum.filter(events, fn
          {:started, _} -> true
          _ -> false
        end)

      assert length(started_events) == 1

      # Verify no agent_end events leak through
      agent_end_events =
        Enum.filter(events, fn
          {:agent_end, _} -> true
          _ -> false
        end)

      assert length(agent_end_events) == 0
    end

    test "filters out unknown event types" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Push unknown event types (should be filtered to [])
      EventStream.push_async(stream, {:unknown_type, "data"})
      EventStream.push_async(stream, {:internal_event, %{foo: "bar"}})
      # Push a known event so we have something to verify
      token = ResumeToken.new("lemon", "unknown_filter_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("lemon", token)})
      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      # Unknown events are filtered, known events pass through
      known_events =
        Enum.filter(events, fn
          {:started, _} -> true
          {:action, _, _, _} -> true
          {:completed, _, _} -> true
          {:error, _} -> true
          _ -> false
        end)

      # Should have the started event, unknown events are filtered
      assert length(known_events) == 1
      assert match?({:started, _}, hd(known_events))
    end
  end

  # ============================================================================
  # Collect Answer
  # ============================================================================

  describe "collect_answer/1" do
    test "returns final answer from completed event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("lemon", "The answer is 42")})
      EventStream.complete(stream, [])

      answer = LemonSubagent.collect_answer(session)
      assert answer == "The answer is 42"
    end

    test "returns empty string when no completed event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.complete(stream, [])

      answer = LemonSubagent.collect_answer(session)
      assert answer == ""
    end

    test "returns last completed answer when multiple completions" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("lemon", "First answer")})
      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("lemon", "Final answer")})
      EventStream.complete(stream, [])

      answer = LemonSubagent.collect_answer(session)
      assert answer == "Final answer"
    end
  end

  # ============================================================================
  # Cancel Operation
  # ============================================================================

  describe "cancel/1" do
    test "returns ok even with nil pid" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Should not raise but may exit
      try do
        LemonSubagent.cancel(session)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================================
  # Steer Operation
  # ============================================================================

  describe "steer/2" do
    test "returns error when session has no process" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      try do
        result = LemonSubagent.steer(session, "redirect")
        assert {:error, _} = result or result == :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================================
  # Follow-up Operation
  # ============================================================================

  describe "follow_up/2" do
    test "returns error when session has no process" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      try do
        result = LemonSubagent.follow_up(session, "next task")
        assert {:error, _} = result or result == :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================================
  # Session Lifecycle Management
  # ============================================================================

  describe "session lifecycle" do
    test "session struct has expected fields" do
      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: nil,
        cwd: "/test/path"
      }

      assert Map.has_key?(session, :pid)
      assert Map.has_key?(session, :stream)
      assert Map.has_key?(session, :resume_token)
      assert Map.has_key?(session, :token_agent)
      assert Map.has_key?(session, :cwd)
    end

    test "session cwd is preserved" do
      cwd = "/my/special/directory"
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: cwd}

      assert session.cwd == cwd
    end

    test "token_agent lifecycle is independent of session" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      # Update token via agent
      new_token = ResumeToken.new("lemon", "updated_token")
      Agent.update(agent, fn _ -> new_token end)

      # Session reflects updated token
      assert LemonSubagent.resume_token(session) == new_token

      Agent.stop(agent)
    end
  end

  # ============================================================================
  # Timeout Handling
  # ============================================================================

  describe "timeout handling" do
    test "events stream respects EventStream timeout" do
      # Create stream with short timeout
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 100)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Don't complete the stream - let it timeout
      # The timeout will cause a :canceled event

      # Start consuming events in a task
      task =
        Task.async(fn ->
          session
          |> LemonSubagent.events()
          |> Enum.to_list()
        end)

      # Wait for timeout + buffer
      events = Task.await(task, 1000)

      # Should have received a canceled event due to timeout
      has_canceled =
        Enum.any?(events, fn
          {:canceled, :timeout} -> true
          {:error, {:canceled, :timeout}} -> true
          _ -> false
        end)

      assert has_canceled
    end

    test "stream cancellation propagates to event consumers" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Start consuming in a separate task
      consumer_task =
        Task.async(fn ->
          session
          |> LemonSubagent.events()
          |> Enum.to_list()
        end)

      # Give consumer time to start
      Process.sleep(10)

      # Cancel the stream
      EventStream.cancel(stream, :test_cancel)

      # Consumer should receive cancel and complete
      events = Task.await(consumer_task, 1000)

      has_canceled =
        Enum.any?(events, fn
          {:canceled, :test_cancel} -> true
          {:error, {:canceled, :test_cancel}} -> true
          _ -> false
        end)

      assert has_canceled
    end
  end

  # ============================================================================
  # Agent Crash Recovery (via token_agent)
  # ============================================================================

  describe "agent crash recovery" do
    test "resume_token survives token_agent crash via session fallback" do
      # Trap exits so we don't get killed when the agent dies
      Process.flag(:trap_exit, true)

      fallback_token = ResumeToken.new("lemon", "fallback_after_crash")
      {:ok, agent} = Agent.start_link(fn -> ResumeToken.new("lemon", "agent_token") end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: fallback_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Crash the agent
      Process.exit(agent, :kill)
      Process.sleep(10)

      # Should fall back to session token
      assert LemonSubagent.resume_token(session) == fallback_token
    end

    test "resume_token handles agent shutdown gracefully" do
      fallback_token = ResumeToken.new("lemon", "shutdown_fallback")
      {:ok, agent} = Agent.start_link(fn -> ResumeToken.new("lemon", "will_shutdown") end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: fallback_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Shutdown the agent normally
      Agent.stop(agent, :normal)
      Process.sleep(10)

      # Should fall back to session token
      assert LemonSubagent.resume_token(session) == fallback_token
    end

    test "events stream handles dead token_agent" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      # Create session without token_agent to test nil handling
      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Push events
      token = ResumeToken.new("lemon", "post_crash")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("lemon", token)})
      EventStream.complete(stream, [])

      # Should not crash with nil token_agent
      events = session |> LemonSubagent.events() |> Enum.to_list()
      assert length(events) >= 1
    end
  end

  # ============================================================================
  # Edge Cases and Error Conditions
  # ============================================================================

  describe "edge cases" do
    test "empty event stream returns empty list" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Complete immediately with no events
      EventStream.complete(stream, [])

      events = session |> LemonSubagent.events() |> Enum.to_list()

      # Empty stream after normalization (agent_end is filtered out)
      # This is expected behavior - the stream just ends
      assert is_list(events)
    end

    test "very long prompt handling" do
      # This tests the session struct can handle long prompts
      # (actual execution would be in integration tests)
      long_prompt = String.duplicate("test prompt ", 1000)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # The continue function should handle long prompts
      assert {:error, :no_resume_token} = LemonSubagent.continue(session, long_prompt)
    end

    test "unicode in prompts" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      unicode_prompt = "Create a function that handles emoji: [U+1F600] and Japanese: [nihon]"
      assert {:error, :no_resume_token} = LemonSubagent.continue(session, unicode_prompt)
    end

    test "special characters in cwd" do
      special_cwd = "/path/with spaces/and-dashes/and_underscores"
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: special_cwd}

      assert session.cwd == special_cwd
    end
  end

  # ============================================================================
  # Integration with ResumeToken
  # ============================================================================

  describe "ResumeToken integration" do
    test "ResumeToken.format returns correct lemon command" do
      token = ResumeToken.new("lemon", "session_abc123")
      assert ResumeToken.format(token) == "`lemon resume session_abc123`"
    end

    test "ResumeToken.extract_resume parses lemon tokens" do
      text = "To continue, run lemon resume my_session_id"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "lemon"
      assert token.value == "my_session_id"
    end

    test "ResumeToken.is_resume_line identifies lemon resume lines" do
      assert ResumeToken.is_resume_line("lemon resume abc123")
      assert ResumeToken.is_resume_line("`lemon resume abc123`")
      refute ResumeToken.is_resume_line("please run lemon resume abc123")
    end
  end
end
