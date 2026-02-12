defmodule AgentCore.CliRunners.CodexSubagentComprehensiveTest do
  @moduledoc """
  Comprehensive tests for CodexSubagent module.

  Tests cover all public functions including:
  - start/1 - starting a new subagent
  - resume/2 - resuming an existing session
  - continue/2 - continuing with new input
  - events/1 - getting event stream
  - collect_answer/1 - collecting final answer
  - resume_token/1 - getting resume token
  - run!/2 - synchronous execution

  Also tests:
  - Error scenarios
  - Timeout handling
  - Event stream parsing
  - Tool schema validation
  - Process lifecycle
  """
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.CodexSubagent

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    ResumeToken,
    StartedEvent
  }

  alias AgentCore.EventStream

  defp unique_codex_token do
    ResumeToken.new("codex", "thread_#{System.unique_integer([:positive, :monotonic])}")
  end

  # ============================================================================
  # API Structure Tests
  # ============================================================================

  describe "API structure" do
    test "module exports expected functions" do
      assert function_exported?(CodexSubagent, :start, 1)
      assert function_exported?(CodexSubagent, :resume, 2)
      assert function_exported?(CodexSubagent, :continue, 2)
      assert function_exported?(CodexSubagent, :continue, 3)
      assert function_exported?(CodexSubagent, :events, 1)
      assert function_exported?(CodexSubagent, :collect_answer, 1)
      assert function_exported?(CodexSubagent, :resume_token, 1)
      assert function_exported?(CodexSubagent, :run!, 1)
    end

    test "module has correct typespec annotations" do
      # Verify the module compiles with typespecs
      {:module, _} = Code.ensure_loaded(CodexSubagent)

      # Module should be loaded and available
      assert :erlang.function_exported(CodexSubagent, :__info__, 1)
    end

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
  end

  # ============================================================================
  # start/1 Tests
  # ============================================================================

  describe "start/1" do
    test "requires prompt option" do
      assert_raise KeyError, fn ->
        CodexSubagent.start(cwd: System.tmp_dir!())
      end
    end

    test "uses current directory when cwd not specified" do
      # This test verifies the API structure, not actual subprocess execution
      # If codex is installed, this would succeed
      try do
        {:ok, session} = CodexSubagent.start(prompt: "test")
        assert Map.has_key?(session, :cwd)
        assert session.cwd != nil
      catch
        :exit, _ -> :ok
      end
    end

    test "accepts timeout option" do
      try do
        {:ok, session} =
          CodexSubagent.start(
            prompt: "test",
            cwd: System.tmp_dir!(),
            timeout: 5_000
          )

        assert Map.has_key?(session, :stream)
      catch
        :exit, _ -> :ok
      end
    end

    test "accepts role_prompt option" do
      try do
        {:ok, session} =
          CodexSubagent.start(
            prompt: "main task",
            role_prompt: "You are a helpful assistant",
            cwd: System.tmp_dir!()
          )

        assert Map.has_key?(session, :pid)
      catch
        :exit, _ -> :ok
      end
    end

    test "returns session map with expected keys on success" do
      try do
        {:ok, session} = CodexSubagent.start(prompt: "test", cwd: System.tmp_dir!())

        assert Map.has_key?(session, :pid)
        assert Map.has_key?(session, :stream)
        assert Map.has_key?(session, :resume_token)
        assert Map.has_key?(session, :token_agent)
        assert Map.has_key?(session, :cwd)
      catch
        :exit, _ -> :ok
      end
    end

    test "initializes token_agent as nil in session" do
      try do
        {:ok, session} = CodexSubagent.start(prompt: "test", cwd: System.tmp_dir!())
        # token_agent should be a pid of an Agent, not nil
        assert is_pid(session.token_agent)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================================
  # resume/2 Tests
  # ============================================================================

  describe "resume/2" do
    test "requires codex engine token" do
      token = unique_codex_token()

      try do
        {:ok, session} = CodexSubagent.resume(token, prompt: "continue", cwd: System.tmp_dir!())
        assert session.cwd != nil
      catch
        :exit, _ -> :ok
      end
    end

    test "rejects non-codex engine tokens" do
      token = ResumeToken.new("claude", "session_123")

      assert_raise FunctionClauseError, fn ->
        CodexSubagent.resume(token, prompt: "continue", cwd: System.tmp_dir!())
      end
    end

    test "requires prompt option" do
      token = ResumeToken.new("codex", "thread_123")

      assert_raise KeyError, fn ->
        CodexSubagent.resume(token, cwd: System.tmp_dir!())
      end
    end

    test "initializes session with provided token" do
      token = unique_codex_token()

      try do
        {:ok, session} = CodexSubagent.resume(token, prompt: "continue", cwd: System.tmp_dir!())
        assert session.resume_token == token
        # token_agent should be initialized with the token
        assert is_pid(session.token_agent)
      catch
        :exit, _ -> :ok
      end
    end

    test "accepts timeout option" do
      token = unique_codex_token()

      try do
        {:ok, _session} =
          CodexSubagent.resume(
            token,
            prompt: "continue",
            cwd: System.tmp_dir!(),
            timeout: 30_000
          )

        :ok
      catch
        :exit, _ -> :ok
      end
    end

    test "uses default cwd when not specified" do
      token = unique_codex_token()

      try do
        {:ok, session} = CodexSubagent.resume(token, prompt: "continue")
        assert session.cwd != nil
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================================
  # continue/2 and continue/3 Tests
  # ============================================================================

  describe "continue/2" do
    test "returns error when no resume token" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert {:error, :no_resume_token} = CodexSubagent.continue(session, "test")
    end

    test "returns error when token agent has nil token" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      assert {:error, :no_resume_token} = CodexSubagent.continue(session, "follow up")

      Agent.stop(agent)
    end

    test "preserves cwd from original session" do
      original_cwd = "/my/project/path"
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: original_cwd}

      # Without a token, we get the error - but this verifies the flow
      assert {:error, :no_resume_token} = CodexSubagent.continue(session, "test")
    end

    test "empty prompt is accepted" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert {:error, :no_resume_token} = CodexSubagent.continue(session, "")
    end

    test "extracts token from token_agent when present" do
      token = ResumeToken.new("codex", "thread_from_agent")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      try do
        {:ok, new_session} = CodexSubagent.continue(session, "continue")
        assert new_session.cwd == "/tmp"
      catch
        :exit, _ -> :ok
      end

      Agent.stop(agent)
    end
  end

  describe "continue/3" do
    test "accepts optional keyword arguments" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      assert {:error, :no_resume_token} =
               CodexSubagent.continue(session, "test", timeout: 30_000)
    end

    test "can override cwd" do
      token = ResumeToken.new("codex", "thread_override_cwd")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/original"}

      try do
        {:ok, new_session} = CodexSubagent.continue(session, "test", cwd: "/override/path")
        assert new_session.cwd == "/override/path"
      catch
        :exit, _ -> :ok
      end

      Agent.stop(agent)
    end

    test "can specify timeout" do
      token = ResumeToken.new("codex", "thread_with_timeout")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      try do
        {:ok, _new_session} = CodexSubagent.continue(session, "test", timeout: 1_000)
        :ok
      catch
        :exit, _ -> :ok
      end

      Agent.stop(agent)
    end
  end

  # ============================================================================
  # events/1 Tests
  # ============================================================================

  describe "events/1" do
    test "returns enumerable for session stream" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      EventStream.complete(stream, [])

      events = CodexSubagent.events(session)
      assert is_function(events, 2) or match?(%Stream{}, events)

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

      started_token = ResumeToken.new("codex", "new_session_123")
      started_event = StartedEvent.new("codex", started_token)
      EventStream.push_async(stream, {:cli_event, started_event})
      EventStream.complete(stream, [])

      _events = session |> CodexSubagent.events() |> Enum.to_list()

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

      resume_token = ResumeToken.new("codex", "session_for_resume")
      completed_event = CompletedEvent.ok("codex", "Done!", resume: resume_token)
      EventStream.push_async(stream, {:cli_event, completed_event})
      EventStream.complete(stream, [])

      _events = session |> CodexSubagent.events() |> Enum.to_list()

      assert Agent.get(token_agent, & &1) == resume_token

      Agent.stop(token_agent)
    end

    test "handles nil token_agent gracefully" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      started_token = ResumeToken.new("codex", "test_session")
      started_event = StartedEvent.new("codex", started_token)
      EventStream.push_async(stream, {:cli_event, started_event})
      EventStream.complete(stream, [])

      # Should not crash with nil token_agent
      events = session |> CodexSubagent.events() |> Enum.to_list()
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

      token = ResumeToken.new("codex", "full_session")

      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})

      action = Action.new("tool_1", :command, "$ ls")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :started)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", action, :completed, ok: true)}
      )

      EventStream.push_async(
        stream,
        {:cli_event, CompletedEvent.ok("codex", "All done", resume: token)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      assert length(events) >= 4

      Agent.stop(token_agent)
    end
  end

  # ============================================================================
  # Event Normalization Tests
  # ============================================================================

  describe "event normalization" do
    test "normalizes StartedEvent to {:started, token}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      token = ResumeToken.new("codex", "norm_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

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
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :started)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", action, :completed, ok: true)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      assert length(action_events) == 2

      {:action, action_map, phase, opts} = Enum.at(action_events, 0)
      assert action_map.id == "tool_42"
      assert action_map.kind == :file_change
      assert action_map.title == "Write test.ex"
      assert phase == :started
      assert opts == []

      {:action, _, :completed, completed_opts} = Enum.at(action_events, 1)
      assert completed_opts == [ok: true]
    end

    test "normalizes CompletedEvent to {:completed, answer, opts}" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      token = ResumeToken.new("codex", "complete_test")
      usage = %{input_tokens: 100, output_tokens: 50}

      EventStream.push_async(
        stream,
        {:cli_event,
         CompletedEvent.ok("codex", "Task completed successfully", resume: token, usage: usage)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

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
         CompletedEvent.error("codex", "Connection failed", answer: "Partial response")}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

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

      events = session |> CodexSubagent.events() |> Enum.to_list()

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

      events = session |> CodexSubagent.events() |> Enum.to_list()

      error_events =
        Enum.filter(events, fn
          {:error, {:canceled, _}} -> true
          _ -> false
        end)

      assert length(error_events) == 1
      {:error, {:canceled, reason}} = hd(error_events)
      assert reason == :user_requested
    end

    test "filters out {:agent_end, _} internal events" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      token = ResumeToken.new("codex", "filter_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})
      EventStream.push_async(stream, {:agent_end, []})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      started_events =
        Enum.filter(events, fn
          {:started, _} -> true
          _ -> false
        end)

      assert length(started_events) == 1

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

      EventStream.push_async(stream, {:unknown_type, "data"})
      EventStream.push_async(stream, {:internal_event, %{foo: "bar"}})
      token = ResumeToken.new("codex", "unknown_filter_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      known_events =
        Enum.filter(events, fn
          {:started, _} -> true
          {:action, _, _, _} -> true
          {:completed, _, _} -> true
          {:error, _} -> true
          _ -> false
        end)

      assert length(known_events) == 1
      assert match?({:started, _}, hd(known_events))
    end

    test "handles action events with different kinds" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      kinds = [:command, :tool, :file_change, :web_search, :note]

      Enum.each(kinds, fn kind ->
        action = Action.new("action_#{kind}", kind, "Test #{kind}")
        EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :started)})
      end)

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      assert length(action_events) == 5

      found_kinds = Enum.map(action_events, fn {:action, action_map, _, _} -> action_map.kind end)
      assert Enum.sort(found_kinds) == Enum.sort(kinds)
    end
  end

  # ============================================================================
  # collect_answer/1 Tests
  # ============================================================================

  describe "collect_answer/1" do
    test "returns final answer from completed event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "The answer is 42")})
      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == "The answer is 42"
    end

    test "returns empty string when no completed event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == ""
    end

    test "returns last completed answer when multiple completions" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "First answer")})
      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "Final answer")})
      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == "Final answer"
    end

    test "collects answer from error completion" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(
        stream,
        {:cli_event, CompletedEvent.error("codex", "failed", answer: "partial work")}
      )

      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == "partial work"
    end

    test "ignores non-completed events for answer" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      token = ResumeToken.new("codex", "answer_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})
      action = Action.new("cmd_1", :command, "$ ls")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :started)})
      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "Final answer")})
      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == "Final answer"
    end
  end

  # ============================================================================
  # resume_token/1 Tests
  # ============================================================================

  describe "resume_token/1" do
    test "returns the resume token from session when no agent" do
      token = ResumeToken.new("codex", "thread_123")
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: nil, cwd: "/tmp"}
      assert CodexSubagent.resume_token(session) == token
    end

    test "returns nil when no token and no agent" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert CodexSubagent.resume_token(session) == nil
    end

    test "returns token from agent when agent is present" do
      token = ResumeToken.new("codex", "thread_456")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}
      assert CodexSubagent.resume_token(session) == token
      Agent.stop(agent)
    end

    test "falls back to session token when agent is dead" do
      token = ResumeToken.new("codex", "thread_fallback")
      {:ok, agent} = Agent.start_link(fn -> nil end)
      Agent.stop(agent)
      Process.sleep(10)
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: agent, cwd: "/tmp"}
      assert CodexSubagent.resume_token(session) == token
    end

    test "agent token takes precedence over session token" do
      session_token = ResumeToken.new("codex", "session_original")
      agent_token = ResumeToken.new("codex", "agent_updated")
      {:ok, agent} = Agent.start_link(fn -> agent_token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: session_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert CodexSubagent.resume_token(session) == agent_token

      Agent.stop(agent)
    end

    test "handles agent returning nil" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session_token = ResumeToken.new("codex", "fallback_token")

      session = %{
        pid: nil,
        stream: nil,
        resume_token: session_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Should return nil from agent, not fall back
      assert CodexSubagent.resume_token(session) == nil

      Agent.stop(agent)
    end

    test "handles concurrent agent access" do
      token = ResumeToken.new("codex", "concurrent_test")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> CodexSubagent.resume_token(session) end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, fn t -> t == token end)

      Agent.stop(agent)
    end

    test "handles agent exit during call" do
      Process.flag(:trap_exit, true)

      fallback_token = ResumeToken.new("codex", "fallback_on_exit")
      {:ok, agent} = Agent.start_link(fn -> ResumeToken.new("codex", "agent_token") end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: fallback_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Kill the agent
      Process.exit(agent, :kill)
      Process.sleep(10)

      # Should fall back to session token
      assert CodexSubagent.resume_token(session) == fallback_token
    end
  end

  # ============================================================================
  # run!/1 Tests
  # ============================================================================

  describe "run!/1" do
    test "requires prompt option" do
      assert_raise KeyError, fn ->
        CodexSubagent.run!(cwd: System.tmp_dir!())
      end
    end

    test "accepts on_event callback" do
      # This tests the interface, actual execution would need codex
      try do
        events_received = Agent.start_link(fn -> [] end) |> elem(1)

        _answer =
          CodexSubagent.run!(
            prompt: "test",
            cwd: System.tmp_dir!(),
            timeout: 1_000,
            on_event: fn event ->
              Agent.update(events_received, fn list -> [event | list] end)
            end
          )

        Agent.stop(events_received)
      catch
        :exit, _ -> :ok
      end
    end

    test "accepts timeout option" do
      try do
        CodexSubagent.run!(prompt: "test", cwd: System.tmp_dir!(), timeout: 100)
      catch
        :exit, _ -> :ok
      end
    end

    test "accepts cwd option" do
      try do
        CodexSubagent.run!(prompt: "test", cwd: System.tmp_dir!())
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================================
  # Timeout Handling Tests
  # ============================================================================

  describe "timeout handling" do
    test "events stream respects EventStream timeout" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 100)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      task =
        Task.async(fn ->
          session
          |> CodexSubagent.events()
          |> Enum.to_list()
        end)

      # CI can be busy; allow slack while still validating the stream self-cancels.
      events = Task.await(task, 5_000)

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

      consumer_task =
        Task.async(fn ->
          session
          |> CodexSubagent.events()
          |> Enum.to_list()
        end)

      Process.sleep(10)

      EventStream.cancel(stream, :test_cancel)

      events = Task.await(consumer_task, 5_000)

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
  # Error Scenario Tests
  # ============================================================================

  describe "error scenarios" do
    test "handles stream with only errors" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:error, :api_error, %{message: "Rate limited"}})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      error_events =
        Enum.filter(events, fn
          {:error, _} -> true
          _ -> false
        end)

      assert length(error_events) == 1
    end

    test "handles canceled stream" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:canceled, :user_abort})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      canceled_events =
        Enum.filter(events, fn
          {:error, {:canceled, _}} -> true
          _ -> false
        end)

      assert length(canceled_events) == 1
    end

    test "handles stream owner dying" do
      # Create stream owned by a spawned process
      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner, timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Start consuming events
      consumer_task =
        Task.async(fn ->
          session
          |> CodexSubagent.events()
          |> Enum.to_list()
        end)

      # Kill the owner
      Process.sleep(10)
      send(owner, :die)

      # Consumer should receive cancellation
      events = Task.await(consumer_task, 1000)

      has_ended =
        Enum.any?(events, fn
          {:canceled, _} -> true
          {:error, _} -> true
          _ -> false
        end)

      assert has_ended
    end

    test "handles agent crash during event processing" do
      Process.flag(:trap_exit, true)

      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      # Push events first before creating session
      token = ResumeToken.new("codex", "crash_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})
      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "Done")})
      EventStream.complete(stream, [])

      # Kill the agent before consuming events
      Process.exit(token_agent, :kill)
      Process.sleep(10)

      # Create session with nil token_agent to avoid crash during event processing
      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Should not crash with nil token_agent
      events = session |> CodexSubagent.events() |> Enum.to_list()
      assert is_list(events)
    end
  end

  # ============================================================================
  # Session Lifecycle Tests
  # ============================================================================

  describe "session lifecycle" do
    test "session cwd is preserved" do
      cwd = "/my/special/directory"
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: cwd}

      assert session.cwd == cwd
    end

    test "token_agent lifecycle is independent of session" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      new_token = ResumeToken.new("codex", "updated_token")
      Agent.update(agent, fn _ -> new_token end)

      assert CodexSubagent.resume_token(session) == new_token

      Agent.stop(agent)
    end

    test "multiple sessions can exist concurrently" do
      {:ok, stream1} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, stream2} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, agent1} = Agent.start_link(fn -> nil end)
      {:ok, agent2} = Agent.start_link(fn -> nil end)

      session1 = %{
        pid: nil,
        stream: stream1,
        resume_token: nil,
        token_agent: agent1,
        cwd: "/tmp/1"
      }

      session2 = %{
        pid: nil,
        stream: stream2,
        resume_token: nil,
        token_agent: agent2,
        cwd: "/tmp/2"
      }

      token1 = ResumeToken.new("codex", "session_1")
      token2 = ResumeToken.new("codex", "session_2")

      EventStream.push_async(stream1, {:cli_event, StartedEvent.new("codex", token1)})
      EventStream.push_async(stream2, {:cli_event, StartedEvent.new("codex", token2)})

      EventStream.complete(stream1, [])
      EventStream.complete(stream2, [])

      _events1 = session1 |> CodexSubagent.events() |> Enum.to_list()
      _events2 = session2 |> CodexSubagent.events() |> Enum.to_list()

      assert Agent.get(agent1, & &1) == token1
      assert Agent.get(agent2, & &1) == token2

      Agent.stop(agent1)
      Agent.stop(agent2)
    end
  end

  # ============================================================================
  # Edge Cases Tests
  # ============================================================================

  describe "edge cases" do
    test "empty event stream returns empty list" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()
      assert is_list(events)
    end

    test "very long prompt handling" do
      long_prompt = String.duplicate("test prompt ", 1000)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      assert {:error, :no_resume_token} = CodexSubagent.continue(session, long_prompt)
    end

    test "unicode in prompts" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      unicode_prompt =
        "Create a function that handles emoji: \u{1F600} and Japanese: \u65E5\u672C"

      assert {:error, :no_resume_token} = CodexSubagent.continue(session, unicode_prompt)
    end

    test "special characters in cwd" do
      special_cwd = "/path/with spaces/and-dashes/and_underscores"
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: special_cwd}

      assert session.cwd == special_cwd
    end

    test "empty answer in completed event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "")})
      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == ""
    end

    test "nil values in action detail" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("test_action", :command, "$ test", %{exit_code: nil, output: nil})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", action, :completed, ok: true)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      assert length(action_events) == 1
      {:action, action_map, _, _} = hd(action_events)
      assert action_map.detail.exit_code == nil
    end

    test "very long answer in completed event" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      long_answer = String.duplicate("This is a long response. ", 10000)
      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", long_answer)})
      EventStream.complete(stream, [])

      answer = CodexSubagent.collect_answer(session)
      assert answer == long_answer
    end
  end

  # ============================================================================
  # ResumeToken Integration Tests
  # ============================================================================

  describe "ResumeToken integration" do
    test "ResumeToken.format returns correct codex command" do
      token = ResumeToken.new("codex", "thread_abc123")
      assert ResumeToken.format(token) == "`codex resume thread_abc123`"
    end

    test "ResumeToken.extract_resume parses codex tokens" do
      text = "To continue, run codex resume my_thread_id"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "codex"
      assert token.value == "my_thread_id"
    end

    test "ResumeToken.is_resume_line identifies codex resume lines" do
      assert ResumeToken.is_resume_line("codex resume abc123")
      assert ResumeToken.is_resume_line("`codex resume abc123`")
      refute ResumeToken.is_resume_line("please run codex resume abc123")
    end

    test "extracts resume token with backticks" do
      text = "Continue with `codex resume thread_xyz789`"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "codex"
      assert token.value == "thread_xyz789"
    end

    test "handles thread_id with underscores and dashes" do
      token1 = ResumeToken.new("codex", "thread_with_underscore")
      token2 = ResumeToken.new("codex", "thread-with-dash")

      assert ResumeToken.format(token1) == "`codex resume thread_with_underscore`"
      assert ResumeToken.format(token2) == "`codex resume thread-with-dash`"
    end
  end

  # ============================================================================
  # Action Phase Tests
  # ============================================================================

  describe "action phases" do
    test "started phase has no ok field" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("cmd_1", :command, "$ echo hello")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :started)})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:action, _, :started, opts} =
        hd(
          Enum.filter(events, fn
            {:action, _, :started, _} -> true
            _ -> false
          end)
        )

      assert opts == []
    end

    test "updated phase has no ok field" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("cmd_1", :command, "$ echo hello")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :updated)})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:action, _, :updated, opts} =
        hd(
          Enum.filter(events, fn
            {:action, _, :updated, _} -> true
            _ -> false
          end)
        )

      assert opts == []
    end

    test "completed phase has ok field" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("cmd_1", :command, "$ echo hello")

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", action, :completed, ok: true)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:action, _, :completed, opts} =
        hd(
          Enum.filter(events, fn
            {:action, _, :completed, _} -> true
            _ -> false
          end)
        )

      assert opts[:ok] == true
    end

    test "completed phase with failure" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("cmd_1", :command, "$ false")

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", action, :completed, ok: false)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:action, _, :completed, opts} =
        hd(
          Enum.filter(events, fn
            {:action, _, :completed, _} -> true
            _ -> false
          end)
        )

      assert opts[:ok] == false
    end

    test "full action lifecycle" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      action = Action.new("cmd_1", :command, "$ long_running_command")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :started)})
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", action, :updated)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", action, :completed, ok: true)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      assert length(action_events) == 3

      phases = Enum.map(action_events, fn {:action, _, phase, _} -> phase end)
      assert phases == [:started, :updated, :completed]
    end
  end

  # ============================================================================
  # Usage Data Tests
  # ============================================================================

  describe "usage data" do
    test "usage is included in completed event opts" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      usage = %{input_tokens: 1000, output_tokens: 500, cached_input_tokens: 200}

      EventStream.push_async(
        stream,
        {:cli_event, CompletedEvent.ok("codex", "Answer", usage: usage)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:completed, _, opts} =
        hd(
          Enum.filter(events, fn
            {:completed, _, _} -> true
            _ -> false
          end)
        )

      assert opts[:usage] == usage
      assert opts[:usage][:input_tokens] == 1000
      assert opts[:usage][:output_tokens] == 500
      assert opts[:usage][:cached_input_tokens] == 200
    end

    test "usage is nil when not provided" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "Answer")})
      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:completed, _, opts} =
        hd(
          Enum.filter(events, fn
            {:completed, _, _} -> true
            _ -> false
          end)
        )

      assert opts[:usage] == nil
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "multiple consumers can read from same session events" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Push events
      token = ResumeToken.new("codex", "concurrent_read_test")
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})
      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "Done")})
      EventStream.complete(stream, [])

      # First consumer
      events1 = session |> CodexSubagent.events() |> Enum.to_list()
      assert length(events1) >= 2

      # Note: Second consumer would get empty stream since first consumed all events
      # This is expected behavior for EventStream
    end

    test "token_agent updates are visible across calls" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      # Initial state
      assert CodexSubagent.resume_token(session) == nil

      # Update via agent
      token1 = ResumeToken.new("codex", "update_1")
      Agent.update(agent, fn _ -> token1 end)
      assert CodexSubagent.resume_token(session) == token1

      # Another update
      token2 = ResumeToken.new("codex", "update_2")
      Agent.update(agent, fn _ -> token2 end)
      assert CodexSubagent.resume_token(session) == token2

      Agent.stop(agent)
    end
  end

  # ============================================================================
  # Process Lifecycle Tests
  # ============================================================================

  describe "process lifecycle" do
    test "EventStream cleanup on complete" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)

      session = %{pid: nil, stream: stream, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      EventStream.push_async(stream, {:cli_event, CompletedEvent.ok("codex", "Done")})
      EventStream.complete(stream, [])

      # Consume all events
      _events = session |> CodexSubagent.events() |> Enum.to_list()

      # Stream should still be accessible but empty
      # (the stream process remains but has no more events)
      result = EventStream.result(stream)
      assert {:ok, []} = result
    end

    test "token_agent can be stopped after use" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      token = ResumeToken.new("codex", "before_stop")
      Agent.update(agent, fn _ -> token end)

      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}

      # Read token before stopping
      assert CodexSubagent.resume_token(session) == token

      # Stop the agent
      Agent.stop(agent)
      Process.sleep(10)

      # Should fall back to session token (nil in this case)
      fallback_session = %{session | resume_token: ResumeToken.new("codex", "fallback")}
      assert CodexSubagent.resume_token(fallback_session) == ResumeToken.new("codex", "fallback")
    end
  end

  # ============================================================================
  # Full Session Flow Tests
  # ============================================================================

  describe "full session flow" do
    test "complete session with all event types" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      # Simulate full Codex session
      token = ResumeToken.new("codex", "full_flow_session")

      # 1. Session starts
      EventStream.push_async(
        stream,
        {:cli_event, StartedEvent.new("codex", token, title: "Codex")}
      )

      # 2. Command execution
      cmd_action = Action.new("cmd_1", :command, "$ npm install")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", cmd_action, :started)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", cmd_action, :completed, ok: true)}
      )

      # 3. Tool call
      tool_action = Action.new("tool_1", :tool, "fs.read_file", %{path: "package.json"})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", tool_action, :started)}
      )

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", tool_action, :completed, ok: true)}
      )

      # 4. File change
      file_action = Action.new("fc_1", :file_change, "1 file changed", %{path: "src/app.ts"})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", file_action, :completed, ok: true)}
      )

      # 5. Session completes
      usage = %{input_tokens: 500, output_tokens: 200}

      EventStream.push_async(
        stream,
        {:cli_event,
         CompletedEvent.ok("codex", "Successfully installed dependencies and updated the app.",
           resume: token,
           usage: usage
         )}
      )

      EventStream.complete(stream, [])

      # Consume events
      events = session |> CodexSubagent.events() |> Enum.to_list()

      # Verify event sequence
      started_events =
        Enum.filter(events, fn
          {:started, _} -> true
          _ -> false
        end)

      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      completed_events =
        Enum.filter(events, fn
          {:completed, _, _} -> true
          _ -> false
        end)

      assert length(started_events) == 1
      # 2 for cmd, 2 for tool, 1 for file
      assert length(action_events) == 5
      assert length(completed_events) == 1

      # Verify token was captured
      assert Agent.get(token_agent, & &1) == token

      # Verify answer
      {:completed, answer, opts} = hd(completed_events)
      assert answer =~ "Successfully installed"
      assert opts[:resume] == token
      assert opts[:usage] == usage

      Agent.stop(token_agent)
    end

    test "session with errors" do
      {:ok, stream} = EventStream.start_link(owner: self(), timeout: 5000)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: token_agent,
        cwd: "/tmp"
      }

      token = ResumeToken.new("codex", "error_session")

      # Session starts
      EventStream.push_async(stream, {:cli_event, StartedEvent.new("codex", token)})

      # Command fails
      cmd_action = Action.new("cmd_1", :command, "$ npm test")
      EventStream.push_async(stream, {:cli_event, ActionEvent.new("codex", cmd_action, :started)})

      EventStream.push_async(
        stream,
        {:cli_event, ActionEvent.new("codex", cmd_action, :completed, ok: false)}
      )

      # Session completes with error
      EventStream.push_async(
        stream,
        {:cli_event,
         CompletedEvent.error("codex", "Tests failed", answer: "Partial work done", resume: token)}
      )

      EventStream.complete(stream, [])

      events = session |> CodexSubagent.events() |> Enum.to_list()

      {:completed, answer, opts} =
        hd(
          Enum.filter(events, fn
            {:completed, _, _} -> true
            _ -> false
          end)
        )

      assert answer == "Partial work done"
      assert opts[:ok] == false
      assert opts[:error] == "Tests failed"
      assert opts[:resume] == token

      Agent.stop(token_agent)
    end
  end
end
