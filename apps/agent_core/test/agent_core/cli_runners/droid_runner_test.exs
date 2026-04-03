defmodule AgentCore.CliRunners.DroidRunnerTest do
  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.DroidRunner
  alias AgentCore.CliRunners.DroidRunner.RunnerState

  alias AgentCore.CliRunners.DroidSchema.{
    DroidCompletionEvent,
    DroidMessageEvent,
    DroidSystemEvent,
    DroidToolCallEvent,
    DroidToolResultEvent
  }

  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  describe "engine/0" do
    test "returns droid" do
      assert DroidRunner.engine() == "droid"
    end
  end

  describe "build_command/3" do
    test "builds command for a new session" do
      state = RunnerState.new("/tmp/project")
      {cmd, args} = DroidRunner.build_command("respond with pong", nil, state)

      assert cmd == "droid"

      assert args == [
               "exec",
               "-o",
               "stream-json",
               "--skip-permissions-unsafe",
               "--cwd",
               "/tmp/project",
               "respond with pong"
             ]
    end

    test "builds command for a resumed session with config flags" do
      config = %LemonCore.Config{
        agent: %{
          cli: %{
            droid: %{
              model: "builder-v1",
              reasoning_effort: "medium",
              enabled_tools: ["grep", "read_file"],
              disabled_tools: ["write"],
              use_spec: true,
              spec_model: "planner-v1",
              extra_args: ["--plain-output"]
            }
          }
        }
      }

      state = RunnerState.new("/tmp/project", config)
      token = ResumeToken.new("droid", "sess_123")
      {cmd, args} = DroidRunner.build_command("continue", token, state)

      assert cmd == "droid"

      assert args == [
               "exec",
               "-o",
               "stream-json",
               "--skip-permissions-unsafe",
               "-s",
               "sess_123",
               "-m",
               "builder-v1",
               "--reasoning-effort",
               "medium",
               "--enabled-tools",
               "grep,read_file",
               "--disabled-tools",
               "write",
               "--use-spec",
               "--spec-model",
               "planner-v1",
               "--plain-output",
               "--cwd",
               "/tmp/project",
               "continue"
             ]
    end

    test "prefers runtime overrides over config" do
      config = %LemonCore.Config{
        agent: %{cli: %{droid: %{model: "config-model", reasoning_effort: "low"}}}
      }

      state =
        RunnerState.new("/tmp/project", config,
          model: "droid:override-model",
          reasoning_effort: "high"
        )

      {_cmd, args} = DroidRunner.build_command("prompt", nil, state)

      assert Enum.at(args, Enum.find_index(args, &(&1 == "-m")) + 1) == "override-model"
      assert Enum.at(args, Enum.find_index(args, &(&1 == "--reasoning-effort")) + 1) == "high"
    end
  end

  describe "env/1" do
    test "injects FACTORY_API_KEY when present" do
      previous = System.get_env("FACTORY_API_KEY")
      System.put_env("FACTORY_API_KEY", "factory-test-key")

      on_exit(fn ->
        if previous,
          do: System.put_env("FACTORY_API_KEY", previous),
          else: System.delete_env("FACTORY_API_KEY")
      end)

      assert DroidRunner.env(RunnerState.new()) == [{"FACTORY_API_KEY", "factory-test-key"}]
    end
  end

  describe "decode_line/1" do
    test "decodes system init events" do
      json =
        ~s|{"type":"system","subtype":"init","cwd":"/tmp","session_id":"sess_1","tools":[],"model":"droid-pro"}|

      assert {:ok,
              %DroidSystemEvent{
                subtype: "init",
                cwd: "/tmp",
                session_id: "sess_1",
                model: "droid-pro"
              }} = DroidRunner.decode_line(json)
    end

    test "decodes message events" do
      json =
        ~s|{"type":"message","role":"assistant","id":"msg_1","text":"pong","timestamp":1,"session_id":"sess_1"}|

      assert {:ok, %DroidMessageEvent{role: "assistant", text: "pong", session_id: "sess_1"}} =
               DroidRunner.decode_line(json)
    end

    test "decodes tool events" do
      call_json =
        ~s|{"type":"tool_call","id":"tc_1","messageId":"msg_1","toolId":"grep","toolName":"grep","parameters":{"pattern":"pong"},"timestamp":1,"session_id":"sess_1"}|

      result_json =
        ~s|{"type":"tool_result","id":"tc_1","messageId":"msg_1","toolId":"grep","isError":false,"value":"1 match","timestamp":2,"session_id":"sess_1"}|

      assert {:ok, %DroidToolCallEvent{id: "tc_1", toolName: "grep"}} =
               DroidRunner.decode_line(call_json)

      assert {:ok, %DroidToolResultEvent{id: "tc_1", isError: false, value: "1 match"}} =
               DroidRunner.decode_line(result_json)
    end

    test "decodes completion events" do
      json =
        ~s|{"type":"completion","finalText":"pong","numTurns":1,"durationMs":25,"session_id":"sess_1","timestamp":3}|

      assert {:ok, %DroidCompletionEvent{finalText: "pong", numTurns: 1, durationMs: 25}} =
               DroidRunner.decode_line(json)
    end

    test "returns error for invalid json" do
      assert {:error, _} = DroidRunner.decode_line("not json")
    end

    test "returns error for unknown event type" do
      assert {:error, {:unknown_event_type, "mystery"}} =
               DroidRunner.decode_line(~s|{"type":"mystery"}|)
    end
  end

  describe "translate_event/2" do
    test "translates init system events to StartedEvent" do
      state = RunnerState.new("/tmp/project")

      event = %DroidSystemEvent{
        subtype: "init",
        cwd: "/tmp/project",
        session_id: "sess_abc",
        tools: [%{"name" => "grep"}],
        model: "droid-pro"
      }

      {events, state, opts} = DroidRunner.translate_event(event, state)

      assert [%StartedEvent{} = started] = events
      assert started.engine == "droid"
      assert started.title == "Droid"
      assert started.resume == ResumeToken.new("droid", "sess_abc")
      assert started.meta.model == "droid-pro"
      assert state.found_session == ResumeToken.new("droid", "sess_abc")
      assert opts == [found_session: ResumeToken.new("droid", "sess_abc")]
    end

    test "tracks assistant messages without emitting events" do
      state = RunnerState.new("/tmp/project")
      event = %DroidMessageEvent{role: "assistant", text: "pong", session_id: "sess_abc"}

      assert {[], state, []} = DroidRunner.translate_event(event, state)
      assert state.last_assistant_text == "pong"
      assert state.found_session == ResumeToken.new("droid", "sess_abc")
    end

    test "translates tool call and result events to action lifecycle events" do
      state = RunnerState.new("/tmp/project")

      call = %DroidToolCallEvent{
        id: "tc_1",
        toolName: "read_file",
        parameters: %{"path" => "/tmp/project/lib/example.ex"},
        session_id: "sess_abc"
      }

      {[started], state, []} = DroidRunner.translate_event(call, state)

      assert %ActionEvent{phase: :started, action: action} = started
      assert action.kind == :tool
      assert action.title == "read: `lib/example.ex`"

      result = %DroidToolResultEvent{
        id: "tc_1",
        isError: false,
        value: "contents",
        session_id: "sess_abc"
      }

      {[completed], state, []} = DroidRunner.translate_event(result, state)

      assert %ActionEvent{phase: :completed, ok: true, action: action} = completed
      assert action.id == "tc_1"
      assert action.detail.result_preview == "contents"
      assert state.pending_actions == %{}
    end

    test "translates completion events to CompletedEvent" do
      state =
        RunnerState.new("/tmp/project")
        |> Map.put(:found_session, ResumeToken.new("droid", "sess_abc"))
        |> Map.put(:last_assistant_text, "fallback answer")

      event = %DroidCompletionEvent{
        finalText: "pong",
        numTurns: 2,
        durationMs: 50,
        session_id: "sess_abc"
      }

      {events, state, opts} = DroidRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == "pong"
      assert completed.resume == ResumeToken.new("droid", "sess_abc")
      assert completed.usage == %{num_turns: 2, duration_ms: 50}
      assert state.found_session == ResumeToken.new("droid", "sess_abc")
      assert opts == [done: true, found_session: ResumeToken.new("droid", "sess_abc")]
    end
  end

  describe "stream handling" do
    test "handle_exit_error/2 emits note and failed completion" do
      state =
        RunnerState.new("/tmp/project")
        |> Map.put(:found_session, ResumeToken.new("droid", "sess_abc"))
        |> Map.put(:last_assistant_text, "partial")

      {events, _state} = DroidRunner.handle_exit_error(2, state)

      assert length(events) == 2
      assert Enum.any?(events, &match?(%ActionEvent{action: %{kind: :warning}}, &1))

      assert Enum.any?(events, fn
               %CompletedEvent{ok: false, answer: "partial", error: "droid exec failed (rc=2)"} ->
                 true

               _ ->
                 false
             end)
    end

    test "handle_stream_end/1 errors when no completion event was seen" do
      state =
        RunnerState.new("/tmp/project")
        |> Map.put(:found_session, ResumeToken.new("droid", "sess_abc"))
        |> Map.put(:last_assistant_text, "partial")

      {[event], _state} = DroidRunner.handle_stream_end(state)

      assert %CompletedEvent{ok: false, answer: "partial"} = event
      assert event.resume.engine == "droid"
      assert event.resume.value == "sess_abc"
    end
  end

  @tag :integration
  @tag :live
  @tag timeout: 120_000
  test "live smoke test returns a completion event" do
    cond do
      is_nil(System.find_executable("droid")) ->
        {:skip, "droid CLI not installed"}

      System.get_env("FACTORY_API_KEY") in [nil, ""] ->
        {:skip, "FACTORY_API_KEY not configured"}

      true ->
        tmp_dir = Path.join(System.tmp_dir!(), "droid_test_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp_dir)
        on_exit(fn -> File.rm_rf!(tmp_dir) end)

        {:ok, pid} =
          DroidRunner.start_link(
            prompt: "respond with just the word pong",
            cwd: tmp_dir,
            timeout: 120_000
          )

        events =
          pid
          |> DroidRunner.stream()
          |> AgentCore.EventStream.events()
          |> Enum.to_list()

        assert Enum.any?(events, &match?({:cli_event, %StartedEvent{engine: "droid"}}, &1))

        assert Enum.any?(events, fn
                 {:cli_event, %CompletedEvent{ok: true, answer: answer}} ->
                   String.contains?(String.downcase(answer), "pong")

                 _ ->
                   false
               end)
    end
  end
end
