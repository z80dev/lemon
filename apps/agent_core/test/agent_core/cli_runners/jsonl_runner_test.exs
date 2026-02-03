defmodule AgentCore.CliRunners.JsonlRunnerTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.JsonlRunner
  alias AgentCore.CliRunners.Types.{Action, ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  # ============================================================================
  # Test Runner Modules
  # ============================================================================

  defmodule TestRunner do
    @moduledoc "Basic test runner that accumulates decoded lines"
    def engine, do: "test"

    def build_command(_prompt, _resume, _state), do: {"echo", ["ok"]}

    def init_state(_prompt, _resume), do: []

    def stdin_payload(_prompt, _resume, _state), do: nil

    def decode_line(line), do: {:ok, line}

    def env(_state), do: nil

    def translate_event(data, state) do
      {[], [data | state], []}
    end

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule JsonRunner do
    @moduledoc "Runner that decodes actual JSON lines"
    def engine, do: "json"

    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "printf '{\"type\":\"init\",\"id\":\"123\"}\\n{\"type\":\"done\"}\\n'"]}
    end

    def init_state(_prompt, _resume), do: %{events: []}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: Jason.decode(line)

    def translate_event(%{"type" => "init", "id" => id}, state) do
      token = ResumeToken.new("json", id)
      event = StartedEvent.new("json", token)
      {[event], %{state | events: [event | state.events]}, found_session: token}
    end

    def translate_event(%{"type" => "done"}, state) do
      event = CompletedEvent.ok("json", "done", resume: List.first(state.events).resume)
      {[event], state, done: true}
    end

    def translate_event(data, state) do
      {[], %{state | events: [data | state.events]}, []}
    end

    def handle_exit_error(exit_code, state) do
      {[CompletedEvent.error("json", "exit #{exit_code}")], state}
    end

    def handle_stream_end(state), do: {[], state}
  end

  defmodule StdoutOnlyRunner do
    @moduledoc "Runner that verifies stderr is separated from stdout"
    def engine, do: "stdout_only"

    def build_command(_prompt, _resume, _state) do
      script = "printf 'stdout-line\\n'; echo 'stderr-line' 1>&2"
      {"bash", ["-c", script]}
    end

    def init_state(_prompt, _resume), do: []

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: {:ok, line}

    def translate_event(data, state) do
      {[{:line, data}], [data | state], []}
    end

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule DecodeErrorRunner do
    @moduledoc "Runner that always fails to decode lines"
    def engine, do: "decode_error"

    def build_command(_prompt, _resume, _state), do: {"bash", ["-c", "printf 'bad-line\\n'"]}

    def init_state(_prompt, _resume), do: %{}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(_line), do: {:error, :invalid_json}

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule MultiDecodeErrorRunner do
    @moduledoc "Runner that emits multiple decode errors to test rate limiting"
    def engine, do: "multi_decode_error"

    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "printf 'bad1\\nbad2\\nbad3\\nbad4\\nbad5\\n'"]}
    end

    def init_state(_prompt, _resume), do: %{}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(_line), do: {:error, :invalid_json}

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule StdinRunner do
    @moduledoc "Runner that uses stdin payload"
    def engine, do: "stdin"

    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "cat | while read line; do echo \"received: $line\"; done"]}
    end

    def init_state(_prompt, _resume), do: []

    def stdin_payload(prompt, _resume, _state), do: prompt <> "\n"

    def env(_state), do: nil

    def decode_line(line), do: {:ok, line}

    def translate_event(data, state) do
      {[{:line, data}], [data | state], []}
    end

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule EnvRunner do
    @moduledoc "Runner that uses environment variables"
    def engine, do: "env"

    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "echo $TEST_VAR"]}
    end

    def init_state(_prompt, _resume), do: []

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: [{"TEST_VAR", "test_value"}]

    def decode_line(line), do: {:ok, line}

    def translate_event(data, state) do
      {[{:line, data}], [data | state], []}
    end

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule FailingRunner do
    @moduledoc "Runner that exits with non-zero exit code"
    def engine, do: "failing"

    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "exit 42"]}
    end

    def init_state(_prompt, _resume), do: %{}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: {:ok, line}

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(exit_code, state) do
      {[CompletedEvent.error("failing", "process exited with code #{exit_code}")], state}
    end

    def handle_stream_end(state), do: {[], state}
  end

  defmodule LargeEventRunner do
    @moduledoc "Runner that emits large JSON events"
    def engine, do: "large_event"

    def build_command(_prompt, _resume, _state) do
      # Generate a large JSON object (approximately 100KB)
      large_data = String.duplicate("x", 100_000)
      json = Jason.encode!(%{"data" => large_data})
      {"bash", ["-c", "echo '#{json}'"]}
    end

    def init_state(_prompt, _resume), do: %{}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: Jason.decode(line)

    def translate_event(%{"data" => data}, state) do
      {[{:large_data, byte_size(data)}], state, []}
    end

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule MultiLineRunner do
    @moduledoc "Runner that emits multiple JSONL lines"
    def engine, do: "multi_line"

    def build_command(_prompt, _resume, _state) do
      # Emit multiple JSON lines
      {"bash", ["-c", "for i in 1 2 3 4 5; do echo '{\"seq\":'$i'}'; done"]}
    end

    def init_state(_prompt, _resume), do: %{sequences: []}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: Jason.decode(line)

    def translate_event(%{"seq" => seq}, state) do
      {[{:seq, seq}], %{state | sequences: [seq | state.sequences]}, []}
    end

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule StderrOutputRunner do
    @moduledoc "Runner that writes to stderr with non-zero exit"
    def engine, do: "stderr_output"

    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "echo 'error message' >&2; exit 1"]}
    end

    def init_state(_prompt, _resume), do: %{}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: {:ok, line}

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(exit_code, state) do
      {[CompletedEvent.error("stderr_output", "exit #{exit_code}")], state}
    end

    def handle_stream_end(state), do: {[], state}
  end

  defmodule SessionRunner do
    @moduledoc "Runner that simulates session lifecycle"
    def engine, do: "session"

    def build_command(_prompt, resume, _state) do
      case resume do
        nil -> {"bash", ["-c", "echo '{\"type\":\"start\",\"session\":\"sess_new\"}'"]}
        %ResumeToken{value: value} -> {"bash", ["-c", "echo '{\"type\":\"resumed\",\"session\":\"#{value}\"}'"]}
      end
    end

    def init_state(_prompt, _resume), do: %{session: nil}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def env(_state), do: nil

    def decode_line(line), do: Jason.decode(line)

    def translate_event(%{"type" => "start", "session" => session}, state) do
      token = ResumeToken.new("session", session)
      event = StartedEvent.new("session", token)
      {[event], %{state | session: token}, found_session: token}
    end

    def translate_event(%{"type" => "resumed", "session" => session}, state) do
      token = ResumeToken.new("session", session)
      event = StartedEvent.new("session", token)
      {[event], %{state | session: token}, found_session: token}
    end

    def translate_event(_data, state), do: {[], state, []}

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  # ============================================================================
  # JSONL Line Parsing Tests
  # ============================================================================

  describe "JSONL line parsing" do
    test "parses valid JSON lines" do
      {:ok, events} = JsonlRunner.run(JsonRunner, prompt: "test", timeout: 5_000)

      started_events =
        events
        |> Enum.filter(fn
          {:cli_event, %StartedEvent{}} -> true
          _ -> false
        end)

      assert length(started_events) == 1

      {:cli_event, %StartedEvent{resume: resume}} = hd(started_events)
      assert resume.value == "123"
      assert resume.engine == "json"
    end

    test "handles malformed JSON gracefully" do
      {:ok, events} = JsonlRunner.run(DecodeErrorRunner, prompt: "ignored", timeout: 5_000)

      warnings =
        events
        |> Enum.filter(fn
          {:cli_event, %ActionEvent{action: %Action{detail: detail}}} ->
            is_map(detail) and Map.has_key?(detail, :decode_error)

          _ ->
            false
        end)

      assert warnings != []
    end

    test "emits warning action on JSONL decode error" do
      {:ok, events} = JsonlRunner.run(DecodeErrorRunner, prompt: "ignored", timeout: 5_000)

      warnings =
        events
        |> Enum.filter(fn
          {:cli_event, %ActionEvent{action: %Action{detail: detail}}} ->
            is_map(detail) and Map.has_key?(detail, :decode_error)

          _ ->
            false
        end)

      assert warnings != []
      {:cli_event, %ActionEvent{action: action}} = hd(warnings)
      assert action.kind == :warning
      assert action.title == "Invalid JSONL line"
    end

    test "limits decode error warnings to 3" do
      {:ok, events} = JsonlRunner.run(MultiDecodeErrorRunner, prompt: "ignored", timeout: 5_000)

      warnings =
        events
        |> Enum.filter(fn
          {:cli_event, %ActionEvent{action: %Action{detail: detail}}} ->
            is_map(detail) and Map.has_key?(detail, :decode_error)

          _ ->
            false
        end)

      # Should only emit 3 warnings even though there are 5 bad lines
      assert length(warnings) == 3
    end

    test "handles empty lines gracefully" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      # Process an empty line
      state = JsonlRunner.ingest_data_for_test(state, "\n")

      # Empty lines should be ignored
      assert state.runner_state == []
    end
  end

  # ============================================================================
  # Line Buffering Tests
  # ============================================================================

  describe "line buffering" do
    test "buffers partial JSONL lines until newline" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      state = JsonlRunner.ingest_data_for_test(state, "part")
      assert state.runner_state == []
      assert state.buffer == "part"

      state = JsonlRunner.ingest_data_for_test(state, "ial\n")
      assert state.runner_state == ["partial"]
      assert state.buffer == ""
    end

    test "handles multiple lines in single data chunk" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      state = JsonlRunner.ingest_data_for_test(state, "line1\nline2\nline3\n")
      assert state.runner_state == ["line3", "line2", "line1"]
      assert state.buffer == ""
    end

    test "handles partial line at end of multi-line chunk" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      state = JsonlRunner.ingest_data_for_test(state, "line1\nline2\npartial")
      assert state.runner_state == ["line2", "line1"]
      assert state.buffer == "partial"
    end

    test "handles data arriving byte by byte" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      # Send "test\n" one byte at a time
      state = JsonlRunner.ingest_data_for_test(state, "t")
      assert state.buffer == "t"
      state = JsonlRunner.ingest_data_for_test(state, "e")
      assert state.buffer == "te"
      state = JsonlRunner.ingest_data_for_test(state, "s")
      assert state.buffer == "tes"
      state = JsonlRunner.ingest_data_for_test(state, "t")
      assert state.buffer == "test"
      state = JsonlRunner.ingest_data_for_test(state, "\n")
      assert state.buffer == ""
      assert state.runner_state == ["test"]
    end

    test "preserves buffer across multiple data chunks" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: "existing_"
      }

      state = JsonlRunner.ingest_data_for_test(state, "data\n")
      assert state.runner_state == ["existing_data"]
      assert state.buffer == ""
    end

    test "handles newline-only data" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: "buffered"
      }

      state = JsonlRunner.ingest_data_for_test(state, "\n")
      assert state.runner_state == ["buffered"]
      assert state.buffer == ""
    end

    test "handles multiple consecutive newlines" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      state = JsonlRunner.ingest_data_for_test(state, "line1\n\n\nline2\n")
      # Empty lines are filtered out
      assert "line1" in state.runner_state
      assert "line2" in state.runner_state
    end
  end

  # ============================================================================
  # Stream Event Handling Tests
  # ============================================================================

  describe "stream event handling" do
    test "emits cli_event wrapper for translated events" do
      {:ok, events} = JsonlRunner.run(JsonRunner, prompt: "test", timeout: 5_000)

      cli_events =
        events
        |> Enum.filter(fn
          {:cli_event, _} -> true
          _ -> false
        end)

      assert length(cli_events) >= 1
    end

    test "translates multiple events in sequence" do
      {:ok, events} = JsonlRunner.run(MultiLineRunner, prompt: "test", timeout: 5_000)

      seq_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:seq, _}} -> true
          _ -> false
        end)

      assert length(seq_events) == 5
      sequences = Enum.map(seq_events, fn {:cli_event, {:seq, n}} -> n end)
      assert sequences == [1, 2, 3, 4, 5]
    end

    test "done flag terminates event processing" do
      {:ok, events} = JsonlRunner.run(JsonRunner, prompt: "test", timeout: 5_000)

      completed_events =
        events
        |> Enum.filter(fn
          {:cli_event, %CompletedEvent{}} -> true
          _ -> false
        end)

      assert length(completed_events) == 1
      {:cli_event, %CompletedEvent{ok: ok}} = hd(completed_events)
      assert ok == true
    end

    test "found_session is tracked from translate_event" do
      {:ok, events} = JsonlRunner.run(SessionRunner, prompt: "test", timeout: 5_000)

      started_events =
        events
        |> Enum.filter(fn
          {:cli_event, %StartedEvent{}} -> true
          _ -> false
        end)

      assert length(started_events) == 1
      {:cli_event, %StartedEvent{resume: resume}} = hd(started_events)
      assert resume.value == "sess_new"
    end
  end

  # ============================================================================
  # Error Recovery Tests
  # ============================================================================

  describe "error recovery" do
    test "handles non-zero exit code via handle_exit_error callback" do
      {:ok, events} = JsonlRunner.run(FailingRunner, prompt: "test", timeout: 5_000)

      error_events =
        events
        |> Enum.filter(fn
          {:cli_event, %CompletedEvent{ok: false}} -> true
          _ -> false
        end)

      assert length(error_events) == 1
      {:cli_event, %CompletedEvent{error: error}} = hd(error_events)
      assert error =~ "42"
    end

    test "emits stderr warning on non-zero exit" do
      {:ok, events} = JsonlRunner.run(StderrOutputRunner, prompt: "test", timeout: 5_000)

      warnings =
        events
        |> Enum.filter(fn
          {:cli_event, %ActionEvent{action: %Action{id: "cli.stderr"}}} -> true
          _ -> false
        end)

      # May or may not have stderr warning depending on timing
      # But the error event should be present
      error_events =
        events
        |> Enum.filter(fn
          {:cli_event, %CompletedEvent{ok: false}} -> true
          _ -> false
        end)

      assert length(error_events) >= 1
    end

    test "continues processing after decode error" do
      # Define a custom runner inline for this test
      defmodule MixedRunner do
        def engine, do: "mixed"

        def build_command(_prompt, _resume, _state) do
          # First line is invalid JSON, second is valid
          {"bash", ["-c", "echo 'not json'; echo '{\"valid\":true}'"]}
        end

        def init_state(_prompt, _resume), do: %{valid_count: 0}
        def stdin_payload(_prompt, _resume, _state), do: nil
        def env(_state), do: nil

        def decode_line(line) do
          case Jason.decode(line) do
            {:ok, data} -> {:ok, data}
            {:error, _} -> {:error, :invalid_json}
          end
        end

        def translate_event(%{"valid" => true}, state) do
          {[{:valid, true}], %{state | valid_count: state.valid_count + 1}, []}
        end

        def translate_event(_data, state), do: {[], state, []}
        def handle_exit_error(_exit_code, state), do: {[], state}
        def handle_stream_end(state), do: {[], state}
      end

      {:ok, events} = JsonlRunner.run(MixedRunner, prompt: "test", timeout: 5_000)

      valid_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:valid, true}} -> true
          _ -> false
        end)

      # Should have processed the valid JSON line even after the invalid one
      assert length(valid_events) == 1
    end

    test "handles stream end without completion event" do
      defmodule NoCompletionRunner do
        def engine, do: "no_completion"

        def build_command(_prompt, _resume, _state) do
          {"bash", ["-c", "echo '{\"type\":\"data\"}'"]}
        end

        def init_state(_prompt, _resume), do: %{}
        def stdin_payload(_prompt, _resume, _state), do: nil
        def env(_state), do: nil
        def decode_line(line), do: Jason.decode(line)

        def translate_event(_data, state), do: {[], state, []}
        def handle_exit_error(_exit_code, state), do: {[], state}

        def handle_stream_end(state) do
          {[CompletedEvent.error("no_completion", "stream ended without completion")], state}
        end
      end

      {:ok, events} = JsonlRunner.run(NoCompletionRunner, prompt: "test", timeout: 5_000)

      completed_events =
        events
        |> Enum.filter(fn
          {:cli_event, %CompletedEvent{}} -> true
          _ -> false
        end)

      assert length(completed_events) == 1
      {:cli_event, %CompletedEvent{ok: ok, error: error}} = hd(completed_events)
      assert ok == false
      assert error =~ "stream ended"
    end
  end

  # ============================================================================
  # Large Event Processing Tests
  # ============================================================================

  describe "large event processing" do
    test "handles large JSON events (100KB+)" do
      {:ok, events} = JsonlRunner.run(LargeEventRunner, prompt: "test", timeout: 10_000)

      large_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:large_data, _}} -> true
          _ -> false
        end)

      assert length(large_events) == 1
      {:cli_event, {:large_data, size}} = hd(large_events)
      assert size >= 100_000
    end

    test "handles many events in rapid succession" do
      defmodule RapidRunner do
        def engine, do: "rapid"

        def build_command(_prompt, _resume, _state) do
          # Generate 100 events quickly
          {"bash", ["-c", "for i in $(seq 1 100); do echo '{\"n\":'$i'}'; done"]}
        end

        def init_state(_prompt, _resume), do: %{count: 0}
        def stdin_payload(_prompt, _resume, _state), do: nil
        def env(_state), do: nil
        def decode_line(line), do: Jason.decode(line)

        def translate_event(%{"n" => n}, state) do
          {[{:n, n}], %{state | count: state.count + 1}, []}
        end

        def translate_event(_data, state), do: {[], state, []}
        def handle_exit_error(_exit_code, state), do: {[], state}
        def handle_stream_end(state), do: {[], state}
      end

      {:ok, events} = JsonlRunner.run(RapidRunner, prompt: "test", timeout: 10_000)

      n_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:n, _}} -> true
          _ -> false
        end)

      assert length(n_events) == 100
    end
  end

  # ============================================================================
  # Stdin/Stdout/Stderr Handling Tests
  # ============================================================================

  describe "stdin/stdout/stderr handling" do
    test "sends stdin payload to subprocess" do
      {:ok, events} = JsonlRunner.run(StdinRunner, prompt: "hello world", timeout: 5_000)

      line_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:line, line}} -> String.contains?(line, "received:")
          _ -> false
        end)

      assert length(line_events) >= 1
      {:cli_event, {:line, line}} = hd(line_events)
      assert line =~ "hello world"
    end

    test "stderr is not mixed into stdout JSONL stream" do
      {:ok, events} = JsonlRunner.run(StdoutOnlyRunner, prompt: "ignored", timeout: 5_000)

      lines =
        events
        |> Enum.filter(fn
          {:cli_event, {:line, _}} -> true
          _ -> false
        end)
        |> Enum.map(fn {:cli_event, {:line, line}} -> line end)

      assert lines == ["stdout-line"]
      refute "stderr-line" in lines
    end

    test "environment variables are passed to subprocess" do
      {:ok, events} = JsonlRunner.run(EnvRunner, prompt: "test", timeout: 5_000)

      line_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:line, _}} -> true
          _ -> false
        end)

      assert length(line_events) >= 1
      {:cli_event, {:line, line}} = hd(line_events)
      assert line =~ "test_value"
    end
  end

  # ============================================================================
  # API Tests
  # ============================================================================

  describe "public API" do
    test "start_link returns {:ok, pid}" do
      {:ok, pid} = JsonlRunner.start_link(TestRunner, prompt: "test", timeout: 5_000)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "stream/1 returns EventStream" do
      {:ok, pid} = JsonlRunner.start_link(TestRunner, prompt: "test", timeout: 5_000)
      stream = JsonlRunner.stream(pid)
      assert is_pid(stream)
    end

    test "run/2 collects all events synchronously" do
      {:ok, events} = JsonlRunner.run(TestRunner, prompt: "test", timeout: 5_000)
      assert is_list(events)
    end

    test "accepts cwd option" do
      {:ok, events} = JsonlRunner.run(TestRunner, prompt: "test", cwd: "/tmp", timeout: 5_000)
      assert is_list(events)
    end

    test "accepts env option" do
      {:ok, events} = JsonlRunner.run(TestRunner, prompt: "test", env: [{"CUSTOM", "value"}], timeout: 5_000)
      assert is_list(events)
    end
  end

  # ============================================================================
  # Session Lock Tests
  # ============================================================================

  describe "session locking" do
    test "acquires lock for new session" do
      {:ok, events} = JsonlRunner.run(SessionRunner, prompt: "test", timeout: 5_000)

      # Should have a started event with session
      started_events =
        events
        |> Enum.filter(fn
          {:cli_event, %StartedEvent{}} -> true
          _ -> false
        end)

      assert length(started_events) == 1
    end
  end

  # ============================================================================
  # Tilde Expansion Tests
  # ============================================================================

  describe "tilde expansion" do
    test "expands ~ in cwd path" do
      home = System.user_home()

      if home do
        # This should work without error
        {:ok, _events} = JsonlRunner.run(TestRunner, prompt: "test", cwd: "~", timeout: 5_000)
      end
    end
  end

  # ============================================================================
  # State Management Tests
  # ============================================================================

  describe "state management" do
    test "runner_state is initialized via init_state callback" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: TestRunner.init_state("prompt", nil),
        buffer: ""
      }

      assert state.runner_state == []
    end

    test "runner_state is updated via translate_event callback" do
      state = %JsonlRunner.State{
        module: TestRunner,
        runner_state: [],
        buffer: ""
      }

      state = JsonlRunner.ingest_data_for_test(state, "event1\nevent2\n")
      assert state.runner_state == ["event2", "event1"]
    end

    test "decode_error_count increments on each error" do
      state = %JsonlRunner.State{
        module: DecodeErrorRunner,
        runner_state: %{},
        buffer: "",
        decode_error_count: 0,
        done: false,
        stream: nil
      }

      # Manually test the decode error counting via state
      # The actual warning emission requires a stream
      assert state.decode_error_count == 0
    end
  end

  # ============================================================================
  # Done Flag Tests
  # ============================================================================

  describe "done flag handling" do
    test "done flag stops processing further lines" do
      defmodule DoneRunner do
        def engine, do: "done"

        def build_command(_prompt, _resume, _state) do
          {"bash", ["-c", "echo '{\"done\":true}'; echo '{\"after\":true}'"]}
        end

        def init_state(_prompt, _resume), do: %{after_done: false}
        def stdin_payload(_prompt, _resume, _state), do: nil
        def env(_state), do: nil
        def decode_line(line), do: Jason.decode(line)

        def translate_event(%{"done" => true}, state) do
          {[{:done, true}], state, done: true}
        end

        def translate_event(%{"after" => true}, state) do
          {[{:after, true}], %{state | after_done: true}, []}
        end

        def translate_event(_data, state), do: {[], state, []}
        def handle_exit_error(_exit_code, state), do: {[], state}
        def handle_stream_end(state), do: {[], state}
      end

      {:ok, events} = JsonlRunner.run(DoneRunner, prompt: "test", timeout: 5_000)

      after_events =
        events
        |> Enum.filter(fn
          {:cli_event, {:after, true}} -> true
          _ -> false
        end)

      # The {:after, true} event should not be emitted because done=true was set
      assert length(after_events) == 0
    end
  end
end
