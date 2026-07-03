defmodule CodingAgent.CliRunners.LemonRunnerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.CliRunners.LemonRunner
  alias CodingAgent.Messages.CustomMessage
  alias CodingAgent.Session
  alias CodingAgent.Session.Presentation
  alias CodingAgent.Session.RunTranslator

  alias AgentCore.Test.Mocks
  alias AgentCore.Types.AgentToolResult

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    EventFactory,
    ResumeToken,
    StartedEvent
  }

  alias AgentCore.EventStream
  alias Ai.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, ThinkingContent, Usage}

  defp mock_model do
    %Model{
      id: "mock-model-1",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: %Usage{
        input: 1,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 2,
        cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
      },
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp mock_stream_fn_single_delayed(response, delay_ms) do
    fn _model, _context, _options ->
      {:ok, stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(stream, {:start, response})
        Ai.EventStream.push(stream, {:text_start, 0, response})

        Ai.EventStream.push(
          stream,
          {:text_delta, 0, CodingAgent.Messages.get_text(response), response}
        )

        Ai.EventStream.push(stream, {:text_end, 0, response})
        Process.sleep(delay_ms)
        Ai.EventStream.push(stream, {:done, response.stop_reason, response})
        Ai.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  # ============================================================================
  # Module API Tests
  # ============================================================================

  describe "module API" do
    test "engine/0 returns 'lemon'" do
      assert LemonRunner.engine() == "lemon"
    end

    test "supports_steer?/0 returns true" do
      assert LemonRunner.supports_steer?() == true
    end

    test "exports cancel/1 and cancel/2 for adapter compatibility" do
      assert function_exported?(LemonRunner, :cancel, 1)
      assert function_exported?(LemonRunner, :cancel, 2)
    end
  end

  # ============================================================================
  # Start Link Tests
  # ============================================================================

  describe "start_link/1" do
    test "requires prompt option" do
      # GenServer.start_link runs init/1 in a separate process, so we get an exit
      # rather than a direct exception. Trap exits to test this gracefully.
      Process.flag(:trap_exit, true)
      result = LemonRunner.start_link(cwd: System.tmp_dir!())

      # Should fail to start - the exact error depends on how GenServer handles
      # the KeyError in init/1
      case result do
        {:error, _reason} ->
          # GenServer returned an error tuple
          :ok

        {:ok, pid} ->
          # If it somehow started, it should exit quickly
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end
    end

    # Note: Full integration tests require CodingAgent.Session to be available,
    # which depends on the coding_agent application being started.
    # These tests are in the coding_agent app's test suite.

    @tag :tmp_dir
    test "router-delivered async followups enter session history as custom messages", %{
      tmp_dir: tmp_dir
    } do
      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "[task task-123] delegated work completed",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: mock_stream_fn_single_delayed(assistant_message("ack"), 200),
          async_followups: [
            %{source: :task, task_id: "task-123", run_id: "run-123", delivery: :router}
          ]
        )

      wait_until(fn ->
        try do
          session = :sys.get_state(runner).session

          Process.alive?(session) and
            Enum.any?(Session.get_messages(session), &match?(%CustomMessage{}, &1))
        catch
          :exit, _ -> false
        end
      end)

      session = :sys.get_state(runner).session
      messages = Session.get_messages(session)

      assert Enum.any?(messages, fn
               %CustomMessage{
                 custom_type: "async_followup",
                 content: "[task task-123] delegated work completed",
                 details: details
               } ->
                 details[:source] == :task and
                   details[:task_id] == "task-123" and
                   details[:run_id] == "run-123"

               _ ->
                 false
             end)
    end

    @tag :tmp_dir
    test "passes run provenance into native session state", %{tmp_dir: tmp_dir} do
      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "hello",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: mock_stream_fn_single_delayed(assistant_message("ack"), 200),
          run_id: "run-lemon-runner",
          session_key: "session-lemon-runner",
          agent_id: "agent-lemon-runner"
        )

      wait_until(fn ->
        try do
          session = :sys.get_state(runner).session
          is_pid(session) and Process.alive?(session)
        catch
          :exit, _ -> false
        end
      end)

      session = :sys.get_state(runner).session
      session_state = Session.get_state(session)

      assert session_state.run_id == "run-lemon-runner"
      assert session_state.session_key == "session-lemon-runner"
      assert session_state.agent_id == "agent-lemon-runner"
    end

    @tag :tmp_dir
    test "preserves structured tool error metadata in action completion events", %{
      tmp_dir: tmp_dir
    } do
      tool_response =
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("missing_tool_for_runner", %{}, id: "call_missing_tool")
        ])

      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "use the missing tool",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: Mocks.mock_stream_fn([tool_response, assistant_message("done")])
        )

      events =
        runner
        |> LemonRunner.stream()
        |> EventStream.events()
        |> Enum.to_list()

      assert {:cli_event,
              %ActionEvent{
                phase: :completed,
                ok: false,
                action: %Action{detail: %{result_meta: result_meta}}
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :completed, action: %Action{id: id}}} ->
                   id == "tool_call_missing_tool"

                 _ ->
                   false
               end)

      assert result_meta.error_type == :unknown_tool
      assert result_meta.tool_name == "missing_tool_for_runner"
    end

    @tag :tmp_dir
    test "emits reasoning action events from thinking stream", %{tmp_dir: tmp_dir} do
      response =
        %AssistantMessage{
          role: :assistant,
          content: [
            %ThinkingContent{type: :thinking, thinking: "checking the subagent path"},
            %TextContent{type: :text, text: "subagent answer"}
          ],
          api: :mock,
          provider: :mock_provider,
          model: "mock-model-1",
          usage: %Usage{
            input: 1,
            output: 1,
            cache_read: 0,
            cache_write: 0,
            total_tokens: 2,
            cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
          },
          stop_reason: :stop,
          timestamp: System.system_time(:millisecond)
        }

      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "think then answer",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: Mocks.mock_stream_fn([response])
        )

      events =
        runner
        |> LemonRunner.stream()
        |> EventStream.events()
        |> Enum.to_list()

      assert {:cli_event,
              %ActionEvent{
                phase: :started,
                action: %Action{
                  id: action_id,
                  kind: :reasoning,
                  detail: %{reasoning: %{text: "checking the subagent path"}}
                }
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :started, action: %Action{kind: :reasoning}}} ->
                   true

                 _ ->
                   false
               end)

      assert {:cli_event,
              %ActionEvent{
                phase: :completed,
                ok: true,
                action: %Action{
                  id: ^action_id,
                  kind: :reasoning,
                  detail: %{reasoning: %{text: "checking the subagent path"}}
                }
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :completed, action: %Action{kind: :reasoning}}} ->
                   true

                 _ ->
                   false
               end)

      assert {:cli_event, %CompletedEvent{ok: true, answer: "subagent answer"}} =
               Enum.find(events, &match?({:cli_event, %CompletedEvent{}}, &1))
    end

    @tag :tmp_dir
    test "emits reasoning updates with the accumulated tail window", %{tmp_dir: tmp_dir} do
      thinking = "start-" <> String.duplicate("middle-", 120) <> "live-tail"
      accumulated = thinking <> thinking
      expected_tail = "..." <> String.slice(accumulated, -500, 500)

      response =
        %AssistantMessage{
          role: :assistant,
          content: [
            %ThinkingContent{type: :thinking, thinking: thinking},
            %TextContent{type: :text, text: "done"}
          ],
          api: :mock,
          provider: :mock_provider,
          model: "mock-model-1",
          usage: %Usage{input: 1, output: 1, total_tokens: 2},
          stop_reason: :stop,
          timestamp: System.system_time(:millisecond)
        }

      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "think then answer",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: Mocks.mock_stream_fn([response])
        )

      events =
        runner
        |> LemonRunner.stream()
        |> EventStream.events()
        |> Enum.to_list()

      assert {:cli_event,
              %ActionEvent{
                phase: :updated,
                action: %Action{
                  kind: :reasoning,
                  detail: %{reasoning: %{text: ^expected_tail}}
                }
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :updated, action: %Action{kind: :reasoning}}} ->
                   true

                 _ ->
                   false
               end)
    end

    @tag :tmp_dir
    test "marks bash actions failed when command exits nonzero", %{tmp_dir: tmp_dir} do
      tool_response =
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("bash", %{"command" => "sh -c 'printf FAIL >&2; exit 7'"},
            id: "call_fail_command"
          )
        ])

      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "run failing command",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: Mocks.mock_stream_fn([tool_response, assistant_message("done")])
        )

      events =
        runner
        |> LemonRunner.stream()
        |> EventStream.events()
        |> Enum.to_list()

      assert {:cli_event,
              %ActionEvent{
                phase: :completed,
                ok: false,
                action: %Action{detail: %{result_meta: result_meta} = detail}
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :completed, action: %Action{id: id}}} ->
                   id == "tool_call_fail_command"

                 _ ->
                   false
               end)

      assert detail.result =~ "Command exited with code 7"
      assert result_meta.error_type == :command_exit
      assert result_meta.tool_name == "bash"
      assert result_meta.exit_code == 7
      assert result_meta.message == "Command exited with code 7"
    end

    @tag :tmp_dir
    test "preserves structured tool error metadata for untracked completion events", %{
      tmp_dir: tmp_dir
    } do
      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "slow tool",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: mock_stream_fn_single_delayed(assistant_message("ack"), 5_000)
        )

      stream = LemonRunner.stream(runner)

      wait_until(fn ->
        try do
          session = :sys.get_state(runner).session
          is_pid(session) and Process.alive?(session)
        catch
          :exit, _ -> false
        end
      end)

      result = %AgentToolResult{
        content: [%TextContent{type: :text, text: "Tool task timed out after 123ms"}],
        details: %{error_type: :tool_task_timeout, timeout_ms: 123, exit_code: 124}
      }

      send(
        runner,
        {:session_event, "manual-session",
         {:tool_execution_end, "orphan_timeout", "slow_tool", result, true}}
      )

      :sys.get_state(runner)
      queue_size = EventStream.stats(stream).queue_size

      events =
        if queue_size > 0 do
          for _ <- 1..queue_size, reduce: [] do
            acc ->
              case GenServer.call(stream, :take, 1_000) do
                {:event, event} -> [event | acc]
                _ -> acc
              end
          end
          |> Enum.reverse()
        else
          []
        end

      GenServer.stop(runner)

      assert {:cli_event,
              %ActionEvent{
                phase: :completed,
                ok: false,
                action: %Action{detail: %{result_meta: result_meta}}
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :completed, action: %Action{id: id}}} ->
                   id == "tool_orphan_timeout"

                 _ ->
                   false
               end)

      assert result_meta.error_type == :tool_task_timeout
      assert result_meta.timeout_ms == 123
      assert result_meta.exit_code == 124
    end

    @tag :tmp_dir
    test "preserves generated auto-send source metadata for tool completions", %{tmp_dir: tmp_dir} do
      {:ok, runner} =
        LemonRunner.start_link(
          prompt: "generate media",
          cwd: tmp_dir,
          model: mock_model(),
          stream_fn: mock_stream_fn_single_delayed(assistant_message("ack"), 5_000)
        )

      stream = LemonRunner.stream(runner)
      path = Path.join(tmp_dir, "generated.svg")
      File.write!(path, "<svg></svg>")

      wait_until(fn ->
        try do
          session = :sys.get_state(runner).session
          is_pid(session) and Process.alive?(session)
        catch
          :exit, _ -> false
        end
      end)

      result = %AgentToolResult{
        content: [%TextContent{type: :text, text: "generated"}],
        details: %{
          "auto_send_files" => [
            %{
              "path" => path,
              "filename" => "generated.svg",
              "caption" => "preview",
              "source" => "generated"
            }
          ]
        }
      }

      send(
        runner,
        {:session_event, "manual-session",
         {:tool_execution_end, "orphan_media", "media_generate_image", result, false}}
      )

      :sys.get_state(runner)
      queue_size = EventStream.stats(stream).queue_size

      events =
        if queue_size > 0 do
          for _ <- 1..queue_size, reduce: [] do
            acc ->
              case GenServer.call(stream, :take, 1_000) do
                {:event, event} -> [event | acc]
                _ -> acc
              end
          end
          |> Enum.reverse()
        else
          []
        end

      GenServer.stop(runner)

      assert {:cli_event,
              %ActionEvent{
                phase: :completed,
                ok: true,
                action: %Action{detail: %{result_meta: result_meta}}
              }} =
               Enum.find(events, fn
                 {:cli_event, %ActionEvent{phase: :completed, action: %Action{id: id}}} ->
                   id == "tool_orphan_media"

                 _ ->
                   false
               end)

      assert [%{path: ^path, filename: "generated.svg", caption: "preview", source: :generated}] =
               result_meta.auto_send_files
    end
  end

  # ============================================================================
  # EventFactory Tests (Unit tests for event creation)
  # ============================================================================

  describe "EventFactory for lemon engine" do
    test "creates factory with lemon engine" do
      factory = EventFactory.new("lemon")
      assert factory.engine == "lemon"
      assert factory.resume == nil
      assert factory.note_seq == 0
    end

    test "started event caches resume token" do
      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "session_12345")

      {event, new_factory} = EventFactory.started(factory, token, meta: %{cwd: "/tmp"})

      assert %StartedEvent{} = event
      assert event.engine == "lemon"
      assert event.resume == token
      assert event.meta == %{cwd: "/tmp"}
      assert new_factory.resume == token
    end

    test "started event raises on engine mismatch" do
      factory = EventFactory.new("lemon")
      wrong_token = ResumeToken.new("claude", "session_wrong")

      assert_raise RuntimeError, ~r/engine mismatch/, fn ->
        EventFactory.started(factory, wrong_token)
      end
    end

    test "action_started creates action event with phase :started" do
      factory = EventFactory.new("lemon")

      {event, _factory} =
        EventFactory.action_started(
          factory,
          "tool_1",
          :command,
          "$ ls -la",
          detail: %{name: "Bash", args: %{"command" => "ls -la"}}
        )

      assert %ActionEvent{} = event
      assert event.engine == "lemon"
      assert event.phase == :started
      assert event.action.id == "tool_1"
      assert event.action.kind == :command
      assert event.action.title == "$ ls -la"
      assert event.action.detail.name == "Bash"
    end

    test "action_updated creates action event with phase :updated" do
      factory = EventFactory.new("lemon")

      {event, _factory} =
        EventFactory.action_updated(
          factory,
          "tool_1",
          :command,
          "$ ls -la",
          detail: %{partial_result: "file1.txt\n"}
        )

      assert event.phase == :updated
      assert event.action.detail.partial_result == "file1.txt\n"
    end

    test "action_completed creates action event with phase :completed" do
      factory = EventFactory.new("lemon")

      {event, _factory} =
        EventFactory.action_completed(
          factory,
          "tool_1",
          :command,
          "$ ls -la",
          true,
          detail: %{result: "file1.txt\nfile2.txt\n"}
        )

      assert event.phase == :completed
      assert event.ok == true
      assert event.action.detail.result == "file1.txt\nfile2.txt\n"
    end

    test "action_completed with failure" do
      factory = EventFactory.new("lemon")

      {event, _factory} =
        EventFactory.action_completed(
          factory,
          "tool_1",
          :command,
          "$ invalid_command",
          false,
          detail: %{result: "command not found"}
        )

      assert event.phase == :completed
      assert event.ok == false
    end

    test "completed_ok creates successful completion event" do
      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "session_123")
      {_event, factory} = EventFactory.started(factory, token)

      {event, _factory} =
        EventFactory.completed_ok(
          factory,
          "Task completed successfully",
          usage: %{input_tokens: 100, output_tokens: 50}
        )

      assert %CompletedEvent{} = event
      assert event.engine == "lemon"
      assert event.ok == true
      assert event.answer == "Task completed successfully"
      assert event.resume == token
      assert event.usage == %{input_tokens: 100, output_tokens: 50}
    end

    test "completed_error creates error completion event" do
      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "session_123")
      {_event, factory} = EventFactory.started(factory, token)

      {event, _factory} =
        EventFactory.completed_error(
          factory,
          "Connection timeout",
          answer: "Partial response before error"
        )

      assert %CompletedEvent{} = event
      assert event.ok == false
      assert event.error == "Connection timeout"
      assert event.answer == "Partial response before error"
      assert event.resume == token
    end

    test "note creates warning action with auto-incrementing ID" do
      factory = EventFactory.new("lemon")

      {event1, factory} = EventFactory.note(factory, "First warning")
      {event2, factory} = EventFactory.note(factory, "Second warning")
      {event3, _factory} = EventFactory.note(factory, "Third warning")

      assert event1.action.id == "note_0"
      assert event2.action.id == "note_1"
      assert event3.action.id == "note_2"

      assert event1.action.kind == :warning
      assert event1.phase == :completed
    end
  end

  # ============================================================================
  # ResumeToken Tests
  # ============================================================================

  describe "ResumeToken for lemon engine" do
    test "creates new token" do
      token = ResumeToken.new("lemon", "abc12345")

      assert token.engine == "lemon"
      assert token.value == "abc12345"
    end

    test "format/1 returns lemon resume command" do
      token = ResumeToken.new("lemon", "abc12345")

      assert ResumeToken.format(token) == "`lemon resume abc12345`"
    end

    test "extract_resume/1 extracts lemon token" do
      text = "You can continue with lemon resume session_xyz123"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "lemon"
      assert token.value == "session_xyz123"
    end

    test "extract_resume/1 extracts lemon token with backticks" do
      text = "Run `lemon resume abc123` to continue"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "lemon"
      assert token.value == "abc123"
    end

    test "extract_resume/2 with specific engine" do
      text = "Run lemon resume abc and claude --resume xyz and kimi --session kimi_123"

      lemon_token = ResumeToken.extract_resume(text, "lemon")
      assert lemon_token.engine == "lemon"
      assert lemon_token.value == "abc"

      claude_token = ResumeToken.extract_resume(text, "claude")
      assert claude_token.engine == "claude"
      assert claude_token.value == "xyz"

      kimi_token = ResumeToken.extract_resume(text, "kimi")
      assert kimi_token.engine == "kimi"
      assert kimi_token.value == "kimi_123"
    end

    test "is_resume_line/1 recognizes lemon resume lines" do
      assert ResumeToken.is_resume_line("lemon resume abc123")
      assert ResumeToken.is_resume_line("`lemon resume abc123`")
      refute ResumeToken.is_resume_line("Please run lemon resume abc123")
      refute ResumeToken.is_resume_line("random text")
    end

    test "is_resume_line/2 with lemon engine" do
      assert ResumeToken.is_resume_line("lemon resume abc123", "lemon")
      refute ResumeToken.is_resume_line("claude --resume abc123", "lemon")
    end
  end

  describe "ResumeToken for kimi engine" do
    test "format/1 returns kimi resume command" do
      token = ResumeToken.new("kimi", "session_987")
      assert ResumeToken.format(token) == "`kimi --session session_987`"
    end

    test "extract_resume/1 extracts kimi token" do
      text = "Continue with `kimi --session kimi_abc123`"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "kimi"
      assert token.value == "kimi_abc123"
    end

    test "is_resume_line/1 recognizes kimi resume lines" do
      assert ResumeToken.is_resume_line("kimi --session abc123")
      assert ResumeToken.is_resume_line("`kimi --session abc123`")
      refute ResumeToken.is_resume_line("Please run kimi --session abc123")
    end
  end

  # ============================================================================
  # Action Type Tests
  # ============================================================================

  describe "Action type" do
    test "creates action with all fields" do
      action = Action.new("tool_123", :file_change, "Write config.ex", %{path: "/app/config.ex"})

      assert action.id == "tool_123"
      assert action.kind == :file_change
      assert action.title == "Write config.ex"
      assert action.detail == %{path: "/app/config.ex"}
    end

    test "creates action with default detail" do
      action = Action.new("tool_456", :tool, "Search files")

      assert action.id == "tool_456"
      assert action.kind == :tool
      assert action.title == "Search files"
      assert action.detail == %{}
    end
  end

  describe "text delta extraction from message updates" do
    alias Ai.Types.{AssistantMessage, TextContent, ThinkingContent, ToolCall}

    test "uses explicit text_delta tuple when present" do
      msg = %AssistantMessage{content: [%TextContent{text: "hello"}]}

      assert Presentation.text_delta_from_message_update(
               msg,
               {:text_delta, 0, "hello", msg},
               ""
             ) == "hello"
    end

    test "falls back to newly visible message text for tool-call events" do
      msg = %AssistantMessage{
        content: [
          %TextContent{text: "Let me read the key files:"},
          %ToolCall{id: "call_1", name: "read", arguments: %{path: "foo.ex"}}
        ]
      }

      assert Presentation.text_delta_from_message_update(
               msg,
               {:tool_call_start, 1, msg},
               ""
             ) == "Let me read the key files:"
    end

    test "does not leak thinking when no visible text exists yet" do
      msg = %AssistantMessage{
        content: [%ThinkingContent{thinking: "I should inspect the provider first."}]
      }

      assert Presentation.text_delta_from_message_update(
               msg,
               {:tool_call_start, 0, msg},
               ""
             ) == nil
    end

    test "does not emit thinking deltas to the user" do
      msg = %AssistantMessage{
        content: [%ThinkingContent{thinking: "I should inspect the provider first."}]
      }

      assert Presentation.text_delta_from_message_update(
               msg,
               {:thinking_delta, 0, "I should inspect the provider first.", msg},
               ""
             ) == nil
    end

    test "prefers visible text over thinking when both are present" do
      msg = %AssistantMessage{
        content: [
          %ThinkingContent{thinking: "I should inspect the provider first."},
          %TextContent{text: "Let me inspect the provider first."}
        ]
      }

      assert Presentation.text_delta_from_message_update(
               msg,
               {:tool_call_start, 1, msg},
               ""
             ) == "Let me inspect the provider first."
    end

    test "emits only the unseen suffix when message already contains prior streamed text" do
      msg = %AssistantMessage{content: [%TextContent{text: "Hello world"}]}

      assert Presentation.text_delta_from_message_update(
               msg,
               {:tool_call_delta, 1, "", msg},
               "Hello "
             ) == "world"
    end

    test "emits only the unseen suffix after a multibyte prefix" do
      msg = %AssistantMessage{content: [%TextContent{text: "héllo é world"}]}

      assert Presentation.text_delta_from_message_update(
               msg,
               {:tool_call_delta, 1, "", msg},
               "héllo é"
             ) == " world"
    end

    test "does not emit duplicate text when visible text has not grown" do
      msg = %AssistantMessage{content: [%TextContent{text: "Hello"}]}

      assert Presentation.text_delta_from_message_update(
               msg,
               {:tool_call_start, 1, msg},
               "Hello"
             ) == nil
    end
  end

  # ============================================================================
  # Tool Kind Mapping Tests (mirrors translate_and_emit logic)
  # ============================================================================

  describe "tool kind mapping" do
    # These tests verify the expected kind mappings based on tool names
    # as documented in the LemonRunner module

    test "Bash maps to :command" do
      assert Presentation.tool_kind("Bash") == :command
    end

    test "Read maps to :tool" do
      assert Presentation.tool_kind("Read") == :tool
    end

    test "Write maps to :file_change" do
      assert Presentation.tool_kind("Write") == :file_change
    end

    test "Edit maps to :file_change" do
      assert Presentation.tool_kind("Edit") == :file_change
    end

    test "Glob maps to :tool" do
      assert Presentation.tool_kind("Glob") == :tool
    end

    test "Grep maps to :tool" do
      assert Presentation.tool_kind("Grep") == :tool
    end

    test "WebSearch maps to :web_search" do
      assert Presentation.tool_kind("WebSearch") == :web_search
    end

    test "WebFetch maps to :web_search" do
      assert Presentation.tool_kind("WebFetch") == :web_search
    end

    test "Task maps to :subagent" do
      assert Presentation.tool_kind("Task") == :subagent
    end

    test "Unknown tool maps to :tool" do
      assert Presentation.tool_kind("CustomTool") == :tool
      assert Presentation.tool_kind("Anything") == :tool
    end
  end

  # ============================================================================
  # Tool Title Generation Tests (mirrors translate_and_emit logic)
  # ============================================================================

  describe "tool title generation" do
    test "Bash with command shows preview" do
      title = Presentation.tool_title("Bash", %{"command" => "ls -la"})
      assert title == "`ls -la`"
    end

    test "Bash truncates long commands" do
      long_cmd = String.duplicate("a", 100)
      title = Presentation.tool_title("Bash", %{"command" => long_cmd})
      assert String.starts_with?(title, "`")
      assert String.ends_with?(title, "`")
      assert String.length(title) <= 62
    end

    test "Bash takes first line of multiline command" do
      title = Presentation.tool_title("Bash", %{"command" => "echo line1\necho line2"})
      assert title == "`echo line1`"
    end

    test "Read shows file basename" do
      title = Presentation.tool_title("Read", %{"file_path" => "/path/to/file.ex"})
      assert title == "read: `to/file.ex`"
    end

    test "Write shows file basename" do
      title = Presentation.tool_title("Write", %{"file_path" => "/path/to/new_file.ex"})
      assert title == "write: `to/new_file.ex`"
    end

    test "Edit shows file basename" do
      title = Presentation.tool_title("Edit", %{"file_path" => "/path/to/edit.ex"})
      assert title == "edit: `to/edit.ex`"
    end

    test "Glob shows pattern" do
      title = Presentation.tool_title("Glob", %{"pattern" => "**/*.ex"})
      assert title == "glob: `**/*.ex`"
    end

    test "Grep shows pattern" do
      title = Presentation.tool_title("Grep", %{"pattern" => "defmodule"})
      assert title == "grep: `defmodule`"
    end

    test "WebSearch shows truncated query" do
      title = Presentation.tool_title("WebSearch", %{"query" => "how to write Elixir tests"})
      assert title == "search: how to write Elixir tests"
    end

    test "WebSearch truncates long query" do
      long_query = String.duplicate("word ", 20)
      title = Presentation.tool_title("WebSearch", %{"query" => long_query})
      assert String.length(title) <= 58
    end

    test "Task shows truncated description" do
      title = Presentation.tool_title("Task", %{"description" => "Review the pull request"})
      assert title == "task: Review the pull request"
    end

    test "Task shows engine suffix for external engines" do
      title =
        Presentation.tool_title("Task", %{
          "description" => "Review the pull request",
          "engine" => "claude"
        })

      assert title == "task(claude): Review the pull request"
    end

    test "Unknown tool shows just the name" do
      title = Presentation.tool_title("CustomTool", %{})
      assert title == "customtool"
    end
  end

  # ============================================================================
  # Result Truncation Tests
  # ============================================================================

  describe "result truncation" do
    test "short results are not truncated" do
      result = "short result"
      assert Presentation.truncate_result(result) == "short result"
    end

    test "AgentToolResult results are rendered as plain text" do
      result = %AgentCore.Types.AgentToolResult{
        content: [%Ai.Types.TextContent{type: :text, text: "ok"}],
        details: nil
      }

      assert Presentation.truncate_result(result) == "ok"
    end

    test "long results are truncated at 500 chars" do
      result = String.duplicate("a", 600)
      truncated = Presentation.truncate_result(result)

      # 500 + "..."
      assert String.length(truncated) == 503
      assert String.ends_with?(truncated, "...")
    end

    test "exactly 500 char result is not truncated" do
      result = String.duplicate("a", 500)
      assert Presentation.truncate_result(result) == result
    end

    test "non-string results are inspected" do
      result = %{key: "value", count: 42}
      truncated = Presentation.truncate_result(result)

      assert is_binary(truncated)
      assert String.contains?(truncated, "key")
    end
  end

  # ============================================================================
  # Error Formatting Tests
  # ============================================================================

  describe "error formatting" do
    test "binary errors pass through" do
      assert Presentation.format_error("Connection failed", %{}) == "Connection failed"
    end

    test "known atom errors use AI formatting" do
      assert Presentation.format_error(:timeout, %{}) == "Request timed out. Please try again."
      assert Presentation.format_error(:econnreset, %{}) == "Connection reset. Please try again."
    end

    test "unknown atom errors are converted to string" do
      assert Presentation.format_error(:connection_refused, %{}) == "connection_refused"
    end

    test "tuple errors are unwrapped" do
      assert Presentation.format_error({:error, "inner error"}, %{}) == "inner error"
      assert Presentation.format_error({:error, :inner_atom}, %{}) == "inner_atom"
    end

    test "assistant_error tuples surface the underlying message" do
      assert Presentation.format_error({:assistant_error, "breaker open"}, %{}) == "breaker open"
    end

    test "http errors use AI formatting" do
      assert Presentation.format_error({:http_error, 503, "overloaded"}, %{}) ==
               "Service temporarily unavailable (HTTP 503): overloaded"
    end

    test "complex terms are inspected" do
      assert Presentation.format_error({:failed, %{reason: :unknown}}, %{}) ==
               "{:failed, %{reason: :unknown}}"
    end
  end

  # ============================================================================
  # Answer Extraction Tests
  # ============================================================================

  describe "answer extraction from messages" do
    test "extracts text from last assistant message with binary content" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "Here is my answer"}
      ]

      assert Presentation.extract_answer(messages, "") == "Here is my answer"
    end

    test "extracts text from list content" do
      messages = [
        %{role: :user, content: "Hello"},
        %{
          role: :assistant,
          content: [
            %{type: :text, text: "First part. "},
            %{type: :text, text: "Second part."}
          ]
        }
      ]

      assert Presentation.extract_answer(messages, "") == "First part. \nSecond part."
    end

    test "falls back to accumulated text when no assistant message" do
      messages = [
        %{role: :user, content: "Hello"}
      ]

      assert Presentation.extract_answer(messages, "accumulated text") == "accumulated text"
    end

    test "falls back to accumulated text when content is nil" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: nil}
      ]

      assert Presentation.extract_answer(messages, "fallback") == "fallback"
    end

    test "finds last assistant message when multiple exist" do
      messages = [
        %{role: :assistant, content: "First response"},
        %{role: :user, content: "Follow up"},
        %{role: :assistant, content: "Latest response"}
      ]

      assert Presentation.extract_answer(messages, "") == "Latest response"
    end
  end

  # ============================================================================
  # Usage Aggregation Tests
  # ============================================================================

  describe "usage aggregation from messages" do
    test "returns nil when no usage present" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "Hi"}
      ]

      assert Presentation.build_usage(messages) == nil
    end

    test "aggregates usage from single message" do
      messages = [
        %{role: :assistant, content: "Hi", usage: %{input_tokens: 10, output_tokens: 5}}
      ]

      usage = Presentation.build_usage(messages)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
    end

    test "sums usage from multiple messages" do
      messages = [
        %{role: :assistant, content: "First", usage: %{input_tokens: 10, output_tokens: 5}},
        %{role: :assistant, content: "Second", usage: %{input_tokens: 15, output_tokens: 8}}
      ]

      usage = Presentation.build_usage(messages)
      assert usage.input_tokens == 25
      assert usage.output_tokens == 13
    end

    test "handles mixed messages with and without usage" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "First", usage: %{input_tokens: 10, output_tokens: 5}},
        %{role: :user, content: "Thanks"},
        %{role: :assistant, content: "Second", usage: %{input_tokens: 20, output_tokens: 10}}
      ]

      usage = Presentation.build_usage(messages)
      assert usage.input_tokens == 30
      assert usage.output_tokens == 15
    end
  end

  # ============================================================================
  # Event Type Tests
  # ============================================================================

  describe "StartedEvent" do
    test "creates event with required fields" do
      token = ResumeToken.new("lemon", "session_123")
      event = StartedEvent.new("lemon", token)

      assert event.type == :started
      assert event.engine == "lemon"
      assert event.resume == token
      assert event.title == nil
      assert event.meta == nil
    end

    test "creates event with optional fields" do
      token = ResumeToken.new("lemon", "session_123")
      event = StartedEvent.new("lemon", token, title: "New Session", meta: %{cwd: "/tmp"})

      assert event.title == "New Session"
      assert event.meta == %{cwd: "/tmp"}
    end
  end

  describe "ActionEvent" do
    test "creates event with required fields" do
      action = Action.new("tool_1", :command, "$ ls")
      event = ActionEvent.new("lemon", action, :started)

      assert event.type == :action
      assert event.engine == "lemon"
      assert event.action == action
      assert event.phase == :started
      assert event.ok == nil
      assert event.message == nil
      assert event.level == nil
    end

    test "creates event with optional fields" do
      action = Action.new("tool_1", :command, "$ ls")

      event =
        ActionEvent.new("lemon", action, :completed,
          ok: true,
          message: "Command succeeded",
          level: :info
        )

      assert event.ok == true
      assert event.message == "Command succeeded"
      assert event.level == :info
    end
  end

  describe "CompletedEvent" do
    test "ok/3 creates successful completion" do
      token = ResumeToken.new("lemon", "session_123")
      event = CompletedEvent.ok("lemon", "Task done", resume: token)

      assert event.type == :completed
      assert event.engine == "lemon"
      assert event.ok == true
      assert event.answer == "Task done"
      assert event.resume == token
      assert event.error == nil
    end

    test "error/3 creates failed completion" do
      token = ResumeToken.new("lemon", "session_123")

      event =
        CompletedEvent.error("lemon", "Timeout",
          resume: token,
          answer: "Partial response"
        )

      assert event.type == :completed
      assert event.ok == false
      assert event.error == "Timeout"
      assert event.answer == "Partial response"
      assert event.resume == token
    end

    test "error/3 defaults answer to empty string" do
      event = CompletedEvent.error("lemon", "Failed")

      assert event.answer == ""
    end
  end

  # ============================================================================
  # Session File Path Tests
  # ============================================================================

  describe "session file path generation" do
    test "generates correct session file path" do
      session_id = "abc12345"
      cwd = "/home/user/project"

      expected = Path.join(CodingAgent.Config.sessions_dir(cwd), "abc12345.jsonl")
      assert Presentation.session_file_path(session_id, cwd) == expected
    end

    test "handles cwd with trailing slash" do
      session_id = "xyz789"
      cwd = "/tmp/"

      # Path.join handles trailing slashes correctly
      expected = Path.join(CodingAgent.Config.sessions_dir(cwd), "xyz789.jsonl")
      assert Presentation.session_file_path(session_id, cwd) == expected
    end
  end

  # ============================================================================
  # Resume Token Validation Tests
  # ============================================================================

  describe "resume token engine validation" do
    test "accepts matching engine" do
      token = ResumeToken.new("lemon", "session_123")
      assert validate_resume_engine(token, "lemon") == :ok
    end

    test "rejects mismatched engine" do
      token = ResumeToken.new("claude", "session_123")

      assert validate_resume_engine(token, "lemon") ==
               {:error, {:wrong_engine, "claude", "lemon"}}
    end

    test "accepts nil token" do
      assert validate_resume_engine(nil, "lemon") == :ok
    end

    # Helper to mirror the session resume validation logic
    defp validate_resume_engine(nil, _expected), do: :ok

    defp validate_resume_engine(%{engine: engine}, expected) when engine == expected, do: :ok

    defp validate_resume_engine(%{engine: other}, expected),
      do: {:error, {:wrong_engine, other, expected}}
  end

  # ============================================================================
  # Event Stream Integration Tests
  # ============================================================================

  describe "EventStream patterns used by LemonRunner" do
    test "EventStream can be created with runner-like options" do
      {:ok, stream} =
        EventStream.start_link(
          max_queue: 10_000,
          drop_strategy: :drop_oldest,
          owner: self(),
          timeout: 600_000
        )

      assert Process.alive?(stream)

      # Clean up
      EventStream.cancel(stream, :test_cleanup)
    end

    test "EventStream push_async accepts cli_event tuples" do
      {:ok, stream} = EventStream.start_link(owner: self())

      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "test_session")
      {started_event, _factory} = EventFactory.started(factory, token)

      # This is how LemonRunner emits events
      :ok = EventStream.push_async(stream, {:cli_event, started_event})

      # Verify the event can be consumed
      events = EventStream.events(stream)

      Task.async(fn ->
        Process.sleep(10)
        EventStream.complete(stream, [])
      end)

      received_events = Enum.to_list(events)
      assert length(received_events) >= 1

      # Find the cli_event we pushed
      cli_events =
        Enum.filter(received_events, fn
          {:cli_event, _} -> true
          _ -> false
        end)

      assert length(cli_events) == 1
      {:cli_event, event} = hd(cli_events)
      assert %StartedEvent{} = event
    end

    test "EventStream complete signals end of stream" do
      {:ok, stream} = EventStream.start_link(owner: self())

      # Push some events
      EventStream.push_async(stream, {:cli_event, :test_event})
      EventStream.complete(stream, [])

      # Verify stream ends
      events = EventStream.events(stream) |> Enum.to_list()

      # Should include the test event and agent_end
      assert Enum.any?(events, fn
               {:cli_event, :test_event} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:agent_end, []} -> true
               _ -> false
             end)
    end
  end

  # ============================================================================
  # State Structure Tests
  # ============================================================================

  describe "LemonRunner state structure" do
    test "state struct has all expected fields" do
      translator =
        RunTranslator.new(
          emitter: LemonRunner.Emitter,
          emitter_state: %LemonRunner.Emitter{stream: nil, factory: EventFactory.new("lemon")},
          engine: "lemon",
          label: "LemonRunner",
          cwd: "/tmp"
        )

      state = %LemonRunner{
        session: nil,
        session_ref: nil,
        session_id: "test_123",
        stream: nil,
        prompt: "test prompt",
        cwd: "/tmp",
        resume: nil,
        translator: translator
      }

      assert state.session_id == "test_123"
      assert state.prompt == "test prompt"
      assert state.cwd == "/tmp"
      assert state.translator.accumulated_text == ""
      assert state.translator.pending_actions == %{}
      assert state.translator.started_emitted == false
      assert state.translator.completed_emitted == false
    end
  end
end
