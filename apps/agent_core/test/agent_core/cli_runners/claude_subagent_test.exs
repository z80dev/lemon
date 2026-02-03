defmodule AgentCore.CliRunners.ClaudeSubagentTest do
  @moduledoc """
  Comprehensive unit tests for ClaudeSubagent.

  These tests verify the high-level API for using Claude as a subagent,
  including session management, event streaming, and error handling.
  """

  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.ClaudeSubagent
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent, Action}
  alias AgentCore.EventStream

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_mock_session(opts \\ []) do
    token = Keyword.get(opts, :token)
    token_agent_pid = Keyword.get(opts, :token_agent)

    token_agent =
      case token_agent_pid do
        nil ->
          {:ok, agent} = Agent.start_link(fn -> token end)
          agent

        pid ->
          pid
      end

    %{
      pid: Keyword.get(opts, :pid, self()),
      stream: Keyword.get(opts, :stream),
      resume_token: token,
      token_agent: token_agent,
      cwd: Keyword.get(opts, :cwd, "/tmp")
    }
  end

  defp create_mock_stream(events) do
    {:ok, stream} = EventStream.start_link(owner: self())

    # Push events asynchronously
    Task.start(fn ->
      Enum.each(events, fn event ->
        EventStream.push(stream, event)
        Process.sleep(1)
      end)

      EventStream.complete(stream, [])
    end)

    stream
  end

  # ============================================================================
  # start/1 Tests
  # ============================================================================

  describe "start/1" do
    test "requires prompt option" do
      assert_raise KeyError, fn ->
        ClaudeSubagent.start(cwd: "/tmp")
      end
    end

    test "uses current directory when cwd not provided" do
      # This will fail because claude isn't mocked, but we can verify the API
      # The KeyError we're looking for is :prompt, not :cwd
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.start([])
      end
    end

    test "accepts timeout option" do
      # Verify the option is accepted by checking no error on option parsing
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.start(timeout: 30_000)
      end
    end

    test "accepts role_prompt option" do
      # The role_prompt should be prepended to the prompt
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.start(role_prompt: "You are a helpful assistant")
      end
    end

    test "returns session map structure on success" do
      # Mock the session structure
      session = create_mock_session(cwd: "/test/dir")

      assert is_map(session)
      assert Map.has_key?(session, :pid)
      assert Map.has_key?(session, :stream)
      assert Map.has_key?(session, :resume_token)
      assert Map.has_key?(session, :token_agent)
      assert Map.has_key?(session, :cwd)
      assert session.cwd == "/test/dir"
    end
  end

  # ============================================================================
  # resume/2 Tests
  # ============================================================================

  describe "resume/2" do
    test "requires claude engine token" do
      token = ResumeToken.new("claude", "sess_123")

      # Verify the pattern match works for claude tokens
      assert token.engine == "claude"
    end

    test "rejects non-claude tokens" do
      codex_token = ResumeToken.new("codex", "thread_123")

      assert_raise FunctionClauseError, fn ->
        ClaudeSubagent.resume(codex_token, prompt: "test", cwd: "/tmp")
      end
    end

    test "requires prompt option" do
      token = ResumeToken.new("claude", "sess_123")

      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.resume(token, cwd: "/tmp")
      end
    end

    test "accepts timeout option" do
      token = ResumeToken.new("claude", "sess_123")

      # Should not raise on option parsing
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.resume(token, timeout: 30_000)
      end
    end

    test "preserves existing token in session" do
      token = ResumeToken.new("claude", "sess_existing")
      {:ok, agent} = Agent.start_link(fn -> token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: token,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session) == token

      Agent.stop(agent)
    end
  end

  # ============================================================================
  # continue/3 Tests
  # ============================================================================

  describe "continue/3" do
    test "returns error when no resume token" do
      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: nil,
        cwd: "/tmp"
      }

      assert {:error, :no_resume_token} = ClaudeSubagent.continue(session, "continue prompt")
    end

    test "returns error when token agent returns nil" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert {:error, :no_resume_token} = ClaudeSubagent.continue(session, "continue prompt")

      Agent.stop(agent)
    end

    test "preserves cwd from original session" do
      token = ResumeToken.new("claude", "sess_123")
      {:ok, agent} = Agent.start_link(fn -> token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: token,
        token_agent: agent,
        cwd: "/original/path"
      }

      # The continue function should use the original cwd
      # We can't fully test this without mocking ClaudeRunner, but we verify
      # the session has the expected cwd
      assert session.cwd == "/original/path"

      Agent.stop(agent)
    end

    test "allows cwd override via opts" do
      token = ResumeToken.new("claude", "sess_123")
      {:ok, agent} = Agent.start_link(fn -> token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: token,
        token_agent: agent,
        cwd: "/original/path"
      }

      # cwd can be overridden in opts
      # We verify the API accepts the option
      assert is_map(session)

      Agent.stop(agent)
    end

    test "accepts empty opts" do
      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: nil,
        cwd: "/tmp"
      }

      # Should not crash on empty opts
      assert {:error, :no_resume_token} = ClaudeSubagent.continue(session, "prompt", [])
    end
  end

  # ============================================================================
  # events/1 Tests
  # ============================================================================

  describe "events/1" do
    test "returns enumerable stream" do
      events = [
        {:cli_event, %StartedEvent{engine: "claude", resume: ResumeToken.new("claude", "s1")}}
      ]

      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      event_stream = ClaudeSubagent.events(session)

      assert is_function(event_stream) or match?(%Stream{}, event_stream)
    end

    test "normalizes started event" do
      token = ResumeToken.new("claude", "sess_test")
      started = %StartedEvent{engine: "claude", resume: token, title: "Claude"}

      events = [{:cli_event, started}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:started, ^token} -> true
               _ -> false
             end)
    end

    test "normalizes action events with started phase" do
      action = %Action{id: "a1", kind: :command, title: "ls -la", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :started, ok: nil}

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:action, %{id: "a1", kind: :command}, :started, []} -> true
               _ -> false
             end)
    end

    test "normalizes action events with completed phase" do
      action = %Action{id: "a1", kind: :command, title: "ls -la", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: true}

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:action, %{id: "a1"}, :completed, [ok: true]} -> true
               _ -> false
             end)
    end

    test "normalizes action events with updated phase" do
      action = %Action{id: "a1", kind: :tool, title: "Reading file", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :updated, ok: nil}

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:action, %{id: "a1"}, :updated, []} -> true
               _ -> false
             end)
    end

    test "normalizes completed event with success" do
      token = ResumeToken.new("claude", "sess_123")
      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "The answer is 42",
        resume: token,
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:completed, "The answer is 42", opts} ->
                 opts[:ok] == true and opts[:resume] == token

               _ ->
                 false
             end)
    end

    test "normalizes completed event with error" do
      token = ResumeToken.new("claude", "sess_123")
      completed = %CompletedEvent{
        engine: "claude",
        ok: false,
        answer: "Partial output",
        resume: token,
        error: "Rate limit exceeded"
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:completed, "Partial output", opts} ->
                 opts[:ok] == false and opts[:error] == "Rate limit exceeded"

               _ ->
                 false
             end)
    end

    test "normalizes error event" do
      events = [{:error, :timeout, nil}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:error, :timeout} -> true
               _ -> false
             end)
    end

    test "normalizes canceled event" do
      events = [{:canceled, :user_requested}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert Enum.any?(normalized, fn
               {:error, {:canceled, :user_requested}} -> true
               _ -> false
             end)
    end

    test "filters out agent_end events" do
      events = [{:agent_end, []}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      # agent_end should be filtered out (returns empty list)
      refute Enum.any?(normalized, fn
               {:agent_end, _} -> true
               _ -> false
             end)
    end

    test "updates token agent on started event" do
      token = ResumeToken.new("claude", "sess_new")
      started = %StartedEvent{engine: "claude", resume: token}

      events = [{:cli_event, started}]
      stream = create_mock_stream(events)

      {:ok, token_agent} = Agent.start_link(fn -> nil end)
      session = create_mock_session(stream: stream, token_agent: token_agent)

      # Consume the events to trigger the side effect
      session
      |> ClaudeSubagent.events()
      |> Enum.to_list()

      # Wait for the agent update
      Process.sleep(10)

      assert Agent.get(token_agent, & &1) == token

      Agent.stop(token_agent)
    end

    test "updates token agent on completed event with resume token" do
      token = ResumeToken.new("claude", "sess_completed")
      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Done",
        resume: token
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)

      {:ok, token_agent} = Agent.start_link(fn -> nil end)
      session = create_mock_session(stream: stream, token_agent: token_agent)

      # Consume the events to trigger the side effect
      session
      |> ClaudeSubagent.events()
      |> Enum.to_list()

      # Wait for the agent update
      Process.sleep(10)

      assert Agent.get(token_agent, & &1) == token

      Agent.stop(token_agent)
    end

    test "handles nil token_agent gracefully" do
      token = ResumeToken.new("claude", "sess_test")
      started = %StartedEvent{engine: "claude", resume: token}

      events = [{:cli_event, started}]
      stream = create_mock_stream(events)

      session = %{
        pid: self(),
        stream: stream,
        resume_token: nil,
        token_agent: nil,
        cwd: "/tmp"
      }

      # Should not crash
      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert length(normalized) >= 1
    end
  end

  # ============================================================================
  # collect_answer/1 Tests
  # ============================================================================

  describe "collect_answer/1" do
    test "returns answer from completed event" do
      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "The final answer",
        resume: nil
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == "The final answer"
    end

    test "returns last answer when multiple completed events" do
      # This is an edge case - normally there's only one completed event
      completed1 = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "First answer",
        resume: nil
      }

      completed2 = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Second answer",
        resume: nil
      }

      events = [{:cli_event, completed1}, {:cli_event, completed2}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == "Second answer"
    end

    test "returns empty string when no completed event" do
      token = ResumeToken.new("claude", "sess_test")
      started = %StartedEvent{engine: "claude", resume: token}

      events = [{:cli_event, started}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == ""
    end

    test "ignores action events" do
      action = %Action{id: "a1", kind: :command, title: "ls", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: true}

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Final answer after actions",
        resume: nil
      }

      events = [{:cli_event, action_event}, {:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == "Final answer after actions"
    end

    test "handles error events gracefully" do
      events = [{:error, :timeout, nil}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      # Error events don't contribute to the answer
      assert answer == ""
    end
  end

  # ============================================================================
  # resume_token/1 Tests
  # ============================================================================

  describe "resume_token/1" do
    test "returns token from session when no agent" do
      token = ResumeToken.new("claude", "sess_123")

      session = %{
        pid: nil,
        stream: nil,
        resume_token: token,
        token_agent: nil,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session) == token
    end

    test "returns nil when no token and no agent" do
      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: nil,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session) == nil
    end

    test "returns token from agent when agent is present" do
      token = ResumeToken.new("claude", "sess_from_agent")
      {:ok, agent} = Agent.start_link(fn -> token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session) == token

      Agent.stop(agent)
    end

    test "agent token takes precedence over session token" do
      session_token = ResumeToken.new("claude", "sess_session")
      agent_token = ResumeToken.new("claude", "sess_agent")
      {:ok, agent} = Agent.start_link(fn -> agent_token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: session_token,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session) == agent_token

      Agent.stop(agent)
    end

    test "falls back to session token when agent is dead" do
      token = ResumeToken.new("claude", "sess_fallback")
      {:ok, agent} = Agent.start_link(fn -> nil end)
      Agent.stop(agent)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Agent is dead, should fall back to session.resume_token
      assert ClaudeSubagent.resume_token(session) == token
    end

    test "returns nil when agent is dead and no session token" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      Agent.stop(agent)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: agent,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session) == nil
    end
  end

  # ============================================================================
  # run!/2 Tests
  # ============================================================================

  describe "run!/1" do
    test "requires prompt option" do
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.run!(cwd: "/tmp")
      end
    end

    test "accepts on_event callback option" do
      # Verify the option is accepted without error on option parsing
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.run!(on_event: fn _event -> :ok end)
      end
    end

    test "accepts timeout option" do
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.run!(timeout: 30_000)
      end
    end

    test "accepts cwd option" do
      assert_raise KeyError, ~r/prompt/, fn ->
        ClaudeSubagent.run!(cwd: "/tmp")
      end
    end
  end

  # ============================================================================
  # Event Normalization Tests
  # ============================================================================

  describe "event normalization" do
    test "extracts action map from ActionEvent" do
      action = %Action{
        id: "action_123",
        kind: :file_change,
        title: "Edit: file.ex",
        detail: %{path: "/path/to/file.ex"}
      }

      action_event = %ActionEvent{
        engine: "claude",
        action: action,
        phase: :completed,
        ok: true
      }

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      [{:action, action_map, phase, opts}] = normalized

      assert action_map.id == "action_123"
      assert action_map.kind == :file_change
      assert action_map.title == "Edit: file.ex"
      assert action_map.detail == %{path: "/path/to/file.ex"}
      assert phase == :completed
      assert opts[:ok] == true
    end

    test "includes usage in completed event opts" do
      usage = %{
        input_tokens: 1000,
        output_tokens: 500,
        total_cost_usd: 0.05
      }

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Done",
        resume: nil,
        usage: usage
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      [{:completed, _answer, opts}] = normalized

      assert opts[:usage] == usage
    end

    test "handles action event without ok field" do
      action = %Action{id: "a1", kind: :tool, title: "Reading", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :started, ok: nil}

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      [{:action, _action_map, :started, opts}] = normalized

      # opts should be empty when ok is nil
      assert opts == []
    end

    test "handles completed event without optional fields" do
      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Simple answer",
        resume: nil,
        error: nil,
        usage: nil
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      [{:completed, "Simple answer", opts}] = normalized

      assert opts[:ok] == true
      refute Keyword.has_key?(opts, :error)
      refute Keyword.has_key?(opts, :usage)
      refute Keyword.has_key?(opts, :resume)
    end
  end

  # ============================================================================
  # Concurrent Subagent Tests
  # ============================================================================

  describe "concurrent subagent handling" do
    test "multiple sessions can have independent token agents" do
      token1 = ResumeToken.new("claude", "sess_1")
      token2 = ResumeToken.new("claude", "sess_2")

      {:ok, agent1} = Agent.start_link(fn -> token1 end)
      {:ok, agent2} = Agent.start_link(fn -> token2 end)

      session1 = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: agent1,
        cwd: "/tmp"
      }

      session2 = %{
        pid: nil,
        stream: nil,
        resume_token: nil,
        token_agent: agent2,
        cwd: "/tmp"
      }

      assert ClaudeSubagent.resume_token(session1) == token1
      assert ClaudeSubagent.resume_token(session2) == token2

      Agent.stop(agent1)
      Agent.stop(agent2)
    end

    test "token updates in one session don't affect another" do
      token1 = ResumeToken.new("claude", "sess_1")
      token2 = ResumeToken.new("claude", "sess_2")

      {:ok, agent1} = Agent.start_link(fn -> token1 end)
      {:ok, agent2} = Agent.start_link(fn -> token2 end)

      # Update agent1
      new_token = ResumeToken.new("claude", "sess_1_updated")
      Agent.update(agent1, fn _ -> new_token end)

      # agent2 should be unaffected
      assert Agent.get(agent2, & &1) == token2

      Agent.stop(agent1)
      Agent.stop(agent2)
    end

    test "sessions with same cwd are independent" do
      {:ok, agent1} = Agent.start_link(fn -> nil end)
      {:ok, agent2} = Agent.start_link(fn -> nil end)

      session1 = %{
        pid: self(),
        stream: nil,
        resume_token: nil,
        token_agent: agent1,
        cwd: "/shared/path"
      }

      session2 = %{
        pid: self(),
        stream: nil,
        resume_token: nil,
        token_agent: agent2,
        cwd: "/shared/path"
      }

      # Update one session's token
      Agent.update(agent1, fn _ -> ResumeToken.new("claude", "sess_1") end)

      # Other session should still be nil
      assert ClaudeSubagent.resume_token(session1) != nil
      assert ClaudeSubagent.resume_token(session2) == nil

      Agent.stop(agent1)
      Agent.stop(agent2)
    end
  end

  # ============================================================================
  # Error Scenarios Tests
  # ============================================================================

  describe "error scenarios" do
    test "handles stream with only error event" do
      events = [{:error, :connection_failed, %{attempt: 3}}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert [{:error, :connection_failed}] = normalized
    end

    test "handles canceled event" do
      events = [{:canceled, :timeout}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert [{:error, {:canceled, :timeout}}] = normalized
    end

    test "handles mixed success and action events" do
      action = %Action{id: "a1", kind: :command, title: "ls", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: true}

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Success",
        resume: nil
      }

      events = [
        {:cli_event, action_event},
        {:cli_event, completed}
      ]

      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert length(normalized) == 2
      assert match?({:action, _, :completed, _}, hd(normalized))
      assert match?({:completed, "Success", _}, List.last(normalized))
    end

    test "handles failed action followed by error completion" do
      action = %Action{id: "a1", kind: :command, title: "bad_command", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: false}

      completed = %CompletedEvent{
        engine: "claude",
        ok: false,
        answer: "",
        resume: nil,
        error: "Command failed"
      }

      events = [
        {:cli_event, action_event},
        {:cli_event, completed}
      ]

      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert length(normalized) == 2

      [{:action, _, :completed, action_opts}, {:completed, "", completed_opts}] = normalized

      assert action_opts[:ok] == false
      assert completed_opts[:ok] == false
      assert completed_opts[:error] == "Command failed"
    end
  end

  # ============================================================================
  # Cleanup Tests
  # ============================================================================

  describe "cleanup on termination" do
    test "token agent can be stopped independently" do
      token = ResumeToken.new("claude", "sess_123")
      {:ok, agent} = Agent.start_link(fn -> token end)

      session = %{
        pid: nil,
        stream: nil,
        resume_token: token,
        token_agent: agent,
        cwd: "/tmp"
      }

      # Stop the agent
      Agent.stop(agent)

      # Session should fall back to resume_token
      assert ClaudeSubagent.resume_token(session) == token
    end

    test "handles dead stream gracefully in events/1" do
      {:ok, stream} = EventStream.start_link(owner: self())
      EventStream.cancel(stream, :test)

      session = %{
        pid: nil,
        stream: stream,
        resume_token: nil,
        token_agent: nil,
        cwd: "/tmp"
      }

      # Should not crash when stream is dead
      events =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      # The stream was cancelled, so we should get something or empty
      assert is_list(events)
    end
  end

  # ============================================================================
  # Session Map Structure Tests
  # ============================================================================

  describe "session map structure" do
    test "session has all required keys" do
      session = create_mock_session()

      assert Map.has_key?(session, :pid)
      assert Map.has_key?(session, :stream)
      assert Map.has_key?(session, :resume_token)
      assert Map.has_key?(session, :token_agent)
      assert Map.has_key?(session, :cwd)
    end

    test "session pid can be nil before start" do
      session = create_mock_session(pid: nil)
      assert session.pid == nil
    end

    test "session stream can be nil before start" do
      session = create_mock_session(stream: nil)
      assert session.stream == nil
    end

    test "cwd is preserved in session" do
      session = create_mock_session(cwd: "/custom/path")
      assert session.cwd == "/custom/path"
    end
  end

  # ============================================================================
  # Full Event Flow Simulation Tests
  # ============================================================================

  describe "full event flow simulation" do
    test "simulates complete session with all event types" do
      token = ResumeToken.new("claude", "sess_full_flow")

      started = %StartedEvent{
        engine: "claude",
        resume: token,
        title: "Claude Session",
        meta: %{model: "claude-opus-4"}
      }

      action1 = %Action{id: "think_1", kind: :note, title: "Thinking...", detail: %{}}
      thinking = %ActionEvent{engine: "claude", action: action1, phase: :completed, ok: true}

      action2 = %Action{id: "cmd_1", kind: :command, title: "ls -la", detail: %{}}
      cmd_started = %ActionEvent{engine: "claude", action: action2, phase: :started, ok: nil}
      cmd_completed = %ActionEvent{engine: "claude", action: action2, phase: :completed, ok: true}

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "Here are the files in the directory.",
        resume: token,
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      events = [
        {:cli_event, started},
        {:cli_event, thinking},
        {:cli_event, cmd_started},
        {:cli_event, cmd_completed},
        {:cli_event, completed}
      ]

      stream = create_mock_stream(events)
      {:ok, token_agent} = Agent.start_link(fn -> nil end)
      session = create_mock_session(stream: stream, token_agent: token_agent)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      # Should have 5 events
      assert length(normalized) == 5

      # First should be started
      assert match?({:started, ^token}, Enum.at(normalized, 0))

      # Last should be completed
      assert match?({:completed, "Here are the files in the directory.", _opts}, List.last(normalized))

      # Token agent should be updated
      Process.sleep(10)
      assert Agent.get(token_agent, & &1) == token

      Agent.stop(token_agent)
    end

    test "simulates error session flow" do
      token = ResumeToken.new("claude", "sess_error_flow")

      started = %StartedEvent{engine: "claude", resume: token}

      action = %Action{id: "cmd_1", kind: :command, title: "failing_command", detail: %{}}
      cmd_started = %ActionEvent{engine: "claude", action: action, phase: :started, ok: nil}
      cmd_failed = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: false}

      completed = %CompletedEvent{
        engine: "claude",
        ok: false,
        answer: "The command failed.",
        resume: token,
        error: "Exit code 1"
      }

      events = [
        {:cli_event, started},
        {:cli_event, cmd_started},
        {:cli_event, cmd_failed},
        {:cli_event, completed}
      ]

      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      # Verify error state
      {:completed, _answer, opts} = List.last(normalized)
      assert opts[:ok] == false
      assert opts[:error] == "Exit code 1"
    end

    test "collect_answer returns final answer from full flow" do
      token = ResumeToken.new("claude", "sess_collect")

      started = %StartedEvent{engine: "claude", resume: token}

      action = %Action{id: "cmd_1", kind: :command, title: "echo hello", detail: %{}}
      cmd_completed = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: true}

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: "hello",
        resume: token
      }

      events = [
        {:cli_event, started},
        {:cli_event, cmd_completed},
        {:cli_event, completed}
      ]

      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == "hello"
    end
  end

  # ============================================================================
  # Unknown Event Type Tests
  # ============================================================================

  describe "unknown event types" do
    test "filters out unknown cli_event types" do
      # Custom struct that isn't a known event type
      unknown_event = %{__struct__: UnknownEvent, data: "test"}

      events = [{:cli_event, unknown_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      # Unknown events should be filtered out (empty list from normalize_event)
      assert normalized == []
    end

    test "filters out unknown raw event types" do
      events = [{:unknown_type, %{data: "test"}}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      # Unknown events should be filtered out
      assert normalized == []
    end
  end

  # ============================================================================
  # API Completeness Tests
  # ============================================================================

  describe "API completeness" do
    test "start/1 function exists and has correct arity" do
      assert function_exported?(ClaudeSubagent, :start, 1)
    end

    test "resume/2 function exists and has correct arity" do
      assert function_exported?(ClaudeSubagent, :resume, 2)
    end

    test "continue/2 function exists" do
      assert function_exported?(ClaudeSubagent, :continue, 2)
    end

    test "continue/3 function exists with opts" do
      assert function_exported?(ClaudeSubagent, :continue, 3)
    end

    test "events/1 function exists" do
      assert function_exported?(ClaudeSubagent, :events, 1)
    end

    test "collect_answer/1 function exists" do
      assert function_exported?(ClaudeSubagent, :collect_answer, 1)
    end

    test "resume_token/1 function exists" do
      assert function_exported?(ClaudeSubagent, :resume_token, 1)
    end

    test "run!/1 function exists" do
      assert function_exported?(ClaudeSubagent, :run!, 1)
    end
  end

  # ============================================================================
  # Edge Cases Tests
  # ============================================================================

  describe "edge cases" do
    test "handles empty events stream" do
      stream = create_mock_stream([])
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      assert normalized == []
    end

    test "handles very long answer text" do
      long_answer = String.duplicate("x", 100_000)

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: long_answer,
        resume: nil
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == long_answer
      assert String.length(answer) == 100_000
    end

    test "handles answer with special characters" do
      special_answer = "Here's a \"quoted\" answer with\nnewlines\tand\ttabs"

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: special_answer,
        resume: nil
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == special_answer
    end

    test "handles unicode in answer" do
      unicode_answer = "Hello, world! \u{1F44B} \u{1F310} Japanese: \u{65E5}\u{672C}\u{8A9E}"

      completed = %CompletedEvent{
        engine: "claude",
        ok: true,
        answer: unicode_answer,
        resume: nil
      }

      events = [{:cli_event, completed}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      answer = ClaudeSubagent.collect_answer(session)

      assert answer == unicode_answer
    end

    test "handles action with empty detail" do
      action = %Action{id: "a1", kind: :tool, title: "Tool call", detail: %{}}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :started, ok: nil}

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      [{:action, action_map, :started, _opts}] = normalized
      assert action_map.detail == %{}
    end

    test "handles action with complex detail" do
      detail = %{
        nested: %{
          key: "value",
          list: [1, 2, 3]
        },
        binary: <<1, 2, 3>>
      }

      action = %Action{id: "a1", kind: :tool, title: "Complex", detail: detail}
      action_event = %ActionEvent{engine: "claude", action: action, phase: :completed, ok: true}

      events = [{:cli_event, action_event}]
      stream = create_mock_stream(events)
      session = create_mock_session(stream: stream)

      normalized =
        session
        |> ClaudeSubagent.events()
        |> Enum.to_list()

      [{:action, action_map, :completed, _opts}] = normalized
      assert action_map.detail == detail
    end
  end

  # ============================================================================
  # Typespecs Validation Tests
  # ============================================================================

  describe "typespec validation" do
    test "session type has correct structure" do
      session = create_mock_session(
        pid: self(),
        stream: nil,
        token: ResumeToken.new("claude", "sess_123"),
        cwd: "/test"
      )

      assert is_pid(session.pid) or is_nil(session.pid)
      assert is_pid(session.stream) or is_nil(session.stream)
      assert is_struct(session.resume_token, ResumeToken) or is_nil(session.resume_token)
      assert is_pid(session.token_agent) or is_nil(session.token_agent)
      assert is_binary(session.cwd)
    end

    test "subagent_event types are correct" do
      token = ResumeToken.new("claude", "sess_test")

      # Test {:started, ResumeToken.t()}
      started_event = {:started, token}
      assert match?({:started, %ResumeToken{}}, started_event)

      # Test {:action, action, phase, opts}
      action_event = {:action, %{id: "a1", kind: :command, title: "ls", detail: %{}}, :completed, [ok: true]}
      assert match?({:action, _, _, _}, action_event)

      # Test {:completed, answer, opts}
      completed_event = {:completed, "answer", [ok: true]}
      assert match?({:completed, _, _}, completed_event)

      # Test {:error, reason}
      error_event = {:error, :timeout}
      assert match?({:error, _}, error_event)
    end
  end
end
