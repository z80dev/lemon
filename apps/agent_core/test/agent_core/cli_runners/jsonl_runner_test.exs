defmodule AgentCore.CliRunners.JsonlRunnerTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.JsonlRunner

  defmodule TestRunner do
    def engine, do: "test"

    def build_command(_prompt, _resume, _state), do: {"echo", ["ok"]}

    def init_state(_prompt, _resume), do: %{}

    def stdin_payload(_prompt, _resume, _state), do: nil

    def decode_line(line), do: {:ok, line}

    def translate_event(data, state) do
      {[], [data | state], []}
    end

    def handle_exit_error(_exit_code, state), do: {[], state}

    def handle_stream_end(state), do: {[], state}
  end

  defmodule StdoutOnlyRunner do
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
  end

  test "emits warning action on JSONL decode error" do
    {:ok, events} = JsonlRunner.run(DecodeErrorRunner, prompt: "ignored", timeout: 5_000)

    warnings =
      events
      |> Enum.filter(fn
        {:cli_event, %AgentCore.CliRunners.Types.ActionEvent{action: %AgentCore.CliRunners.Types.Action{detail: detail}}} ->
          is_map(detail) and Map.has_key?(detail, :decode_error)

        _ ->
          false
      end)

    assert warnings != []
  end
end
