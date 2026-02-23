defmodule AgentCore.CliRunners.IntrospectionTest do
  @moduledoc """
  Tests that M3 introspection events are emitted by CLI runner adapters.

  Each runner's translate_event/handle_exit_error/handle_stream_end callbacks
  are invoked directly and then verified via `Introspection.list/1`.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Introspection

  # Runner aliases
  alias AgentCore.CliRunners.CodexRunner
  alias AgentCore.CliRunners.ClaudeRunner
  alias AgentCore.CliRunners.KimiRunner
  alias AgentCore.CliRunners.OpencodeRunner
  alias AgentCore.CliRunners.PiRunner

  # Schema aliases for building test events
  alias AgentCore.CliRunners.CodexSchema.{ThreadStarted, TurnCompleted, Usage}
  alias AgentCore.CliRunners.ClaudeSchema.StreamSystemMessage
  alias AgentCore.CliRunners.OpencodeSchema.{StepStart, StepFinish}
  alias AgentCore.CliRunners.PiSchema.{AgentEnd, SessionHeader}

  alias AgentCore.CliRunners.Types.ResumeToken

  setup do
    # Ensure introspection is enabled for all tests
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))

    # Capture timestamp before each test to filter out events from other tests
    ts_before = System.system_time(:millisecond)

    on_exit(fn ->
      Application.put_env(:lemon_core, :introspection, original)
    end)

    %{ts_before: ts_before}
  end

  # Helper: get introspection events emitted since ts_before, matching engine and event_type
  defp events_since(event_type, engine, ts_before) do
    Introspection.list(event_type: event_type, since_ms: ts_before, limit: 100)
    |> Enum.filter(&(&1.engine == engine))
  end

  # ============================================================================
  # Codex Runner Introspection
  # ============================================================================

  describe "CodexRunner introspection" do
    test "emits :engine_subprocess_started on ThreadStarted", %{ts_before: ts_before} do
      state = CodexRunner.RunnerState.new()
      event = %ThreadStarted{thread_id: "thread_intro_test"}

      {_events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      evts = events_since(:engine_subprocess_started, "codex", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
      assert evt.payload.engine == "codex"
    end

    test "emits :engine_output_observed on TurnCompleted", %{ts_before: ts_before} do
      state = %{
        CodexRunner.RunnerState.new()
        | final_answer: "Done!",
          found_session: ResumeToken.new("codex", "thread_output_test")
      }

      event = %TurnCompleted{usage: %Usage{input_tokens: 100, output_tokens: 50}}

      {_events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      evts = events_since(:engine_output_observed, "codex", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
      assert evt.payload.input_tokens == 100
      assert evt.payload.output_tokens == 50
    end

    test "emits :engine_subprocess_exited on handle_exit_error", %{ts_before: ts_before} do
      state = CodexRunner.RunnerState.new()

      {_events, _new_state} = CodexRunner.handle_exit_error(11, state)

      evts = events_since(:engine_subprocess_exited, "codex", ts_before)
      assert length(evts) >= 1
      evt = Enum.find(evts, &(&1.payload.exit_code == 11))
      assert evt != nil
      assert evt.provenance == :inferred
      assert evt.payload.ok == false
    end
  end

  # ============================================================================
  # Claude Runner Introspection
  # ============================================================================

  describe "ClaudeRunner introspection" do
    test "emits :engine_subprocess_started on init StreamSystemMessage", %{ts_before: ts_before} do
      state = ClaudeRunner.RunnerState.new()

      init_msg = %StreamSystemMessage{
        session_id: "ses_intro_test",
        model: "claude-opus-4-20250514",
        tools: [],
        type: "system",
        subtype: "init"
      }

      {_events, _new_state, _opts} = ClaudeRunner.translate_event(init_msg, state)

      evts = events_since(:engine_subprocess_started, "claude", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
    end

    test "emits :engine_subprocess_exited on handle_exit_error", %{ts_before: ts_before} do
      state = ClaudeRunner.RunnerState.new()

      {_events, _new_state} = ClaudeRunner.handle_exit_error(7, state)

      evts = events_since(:engine_subprocess_exited, "claude", ts_before)
      assert length(evts) >= 1
      evt = Enum.find(evts, &(&1.payload.exit_code == 7))
      assert evt != nil
      assert evt.payload.ok == false
    end
  end

  # ============================================================================
  # Kimi Runner Introspection
  # ============================================================================

  describe "KimiRunner introspection" do
    test "emits :engine_subprocess_exited on handle_exit_error", %{ts_before: ts_before} do
      state = KimiRunner.RunnerState.new(nil, nil, nil)

      {_events, _new_state} = KimiRunner.handle_exit_error(42, state)

      evts = events_since(:engine_subprocess_exited, "kimi", ts_before)
      assert length(evts) >= 1
      evt = Enum.find(evts, &(&1.payload.exit_code == 42))
      assert evt != nil
      assert evt.provenance == :inferred
      assert evt.payload.ok == false
    end

    test "emits :engine_output_observed on handle_stream_end with answer", %{
      ts_before: ts_before
    } do
      state = %{
        KimiRunner.RunnerState.new(nil, nil, nil)
        | last_assistant_text: "Here is the answer"
      }

      {_events, _new_state} = KimiRunner.handle_stream_end(state)

      evts = events_since(:engine_output_observed, "kimi", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
      assert evt.payload.ok == true
      assert evt.payload.has_answer == true
    end

    test "does not emit :engine_output_observed on handle_stream_end without answer", %{
      ts_before: _ts_before
    } do
      before_count =
        Introspection.list(event_type: :engine_output_observed, limit: 500)
        |> Enum.count(&(&1.engine == "kimi"))

      state = KimiRunner.RunnerState.new(nil, nil, nil)

      {_events, _new_state} = KimiRunner.handle_stream_end(state)

      after_count =
        Introspection.list(event_type: :engine_output_observed, limit: 500)
        |> Enum.count(&(&1.engine == "kimi"))

      # Our call should not have added any new events
      assert after_count == before_count
    end
  end

  # ============================================================================
  # OpenCode Runner Introspection
  # ============================================================================

  describe "OpencodeRunner introspection" do
    test "emits :engine_subprocess_started on maybe_emit_started via StepStart", %{
      ts_before: ts_before
    } do
      state = OpencodeRunner.RunnerState.new(nil)

      {_events, _new_state, _opts} =
        OpencodeRunner.translate_event(%StepStart{sessionID: "ses_oc_test"}, state)

      evts = events_since(:engine_subprocess_started, "opencode", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
    end

    test "emits :engine_output_observed on StepFinish reason=stop", %{ts_before: ts_before} do
      state = OpencodeRunner.RunnerState.new(nil)
      {_, state, _} = OpencodeRunner.translate_event(%StepStart{sessionID: "ses_oc_out"}, state)

      finish = %StepFinish{sessionID: "ses_oc_out", part: %{"reason" => "stop"}}
      {_events, _new_state, _opts} = OpencodeRunner.translate_event(finish, state)

      evts = events_since(:engine_output_observed, "opencode", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
      assert evt.payload.ok == true
    end

    test "emits :engine_subprocess_exited on handle_exit_error", %{ts_before: ts_before} do
      state = OpencodeRunner.RunnerState.new(nil)

      {_events, _new_state} = OpencodeRunner.handle_exit_error(22, state)

      evts = events_since(:engine_subprocess_exited, "opencode", ts_before)
      assert length(evts) >= 1
      evt = Enum.find(evts, &(&1.payload.exit_code == 22))
      assert evt != nil
      assert evt.provenance == :inferred
      assert evt.payload.ok == false
    end
  end

  # ============================================================================
  # Pi Runner Introspection
  # ============================================================================

  describe "PiRunner introspection" do
    test "emits :engine_subprocess_started on maybe_emit_started", %{ts_before: ts_before} do
      state = PiRunner.RunnerState.new(nil)

      # Translate any event to trigger maybe_emit_started
      {_events, _new_state, _opts} =
        PiRunner.translate_event(%SessionHeader{id: "pi_session_test"}, state)

      evts = events_since(:engine_subprocess_started, "pi", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
    end

    test "emits :engine_output_observed on AgentEnd", %{ts_before: ts_before} do
      state = PiRunner.RunnerState.new(nil)
      # Trigger started first
      {_, state, _} = PiRunner.translate_event(%SessionHeader{id: "pi_out_test"}, state)

      agent_end = %AgentEnd{
        messages: [
          %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Done"}],
            "stopReason" => "end_turn"
          }
        ]
      }

      {_events, _new_state, _opts} = PiRunner.translate_event(agent_end, state)

      evts = events_since(:engine_output_observed, "pi", ts_before)
      assert length(evts) >= 1
      evt = List.last(evts)
      assert evt.provenance == :inferred
      assert evt.payload.ok == true
      assert evt.payload.has_answer == true
    end

    test "emits :engine_subprocess_exited on handle_exit_error", %{ts_before: ts_before} do
      state = PiRunner.RunnerState.new(nil)

      {_events, _new_state} = PiRunner.handle_exit_error(33, state)

      evts = events_since(:engine_subprocess_exited, "pi", ts_before)
      assert length(evts) >= 1
      evt = Enum.find(evts, &(&1.payload.exit_code == 33))
      assert evt != nil
      assert evt.provenance == :inferred
      assert evt.payload.ok == false
    end
  end

  # ============================================================================
  # Cross-runner provenance contract
  # ============================================================================

  describe "provenance contract" do
    test "all CLI runner introspection events use :inferred provenance", %{ts_before: ts_before} do
      # Trigger events from multiple runners
      codex_state = CodexRunner.RunnerState.new()
      CodexRunner.handle_exit_error(1, codex_state)

      claude_state = ClaudeRunner.RunnerState.new()
      ClaudeRunner.handle_exit_error(1, claude_state)

      oc_state = OpencodeRunner.RunnerState.new(nil)
      OpencodeRunner.handle_exit_error(1, oc_state)

      kimi_state = KimiRunner.RunnerState.new(nil, nil, nil)
      KimiRunner.handle_exit_error(1, kimi_state)

      pi_state = PiRunner.RunnerState.new(nil)
      PiRunner.handle_exit_error(1, pi_state)

      # Check all engine_subprocess_exited events emitted in this test are :inferred
      events =
        Introspection.list(
          event_type: :engine_subprocess_exited,
          since_ms: ts_before,
          limit: 50
        )

      assert length(events) >= 5

      for event <- events do
        assert event.provenance == :inferred,
               "Expected :inferred provenance for engine_subprocess_exited from engine=#{event.engine}, got #{event.provenance}"
      end
    end
  end
end
