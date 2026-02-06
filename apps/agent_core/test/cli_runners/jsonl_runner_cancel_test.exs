defmodule AgentCore.CliRunners.JsonlRunnerCancelTest do
  use ExUnit.Case

  defmodule DummyRunner do
    use AgentCore.CliRunners.JsonlRunner

    @impl true
    def engine, do: "dummy"

    @impl true
    def build_command(_prompt, _resume, _state) do
      {"sleep", ["5"]}
    end

    @impl true
    def decode_line(_line), do: {:error, :noop}

    @impl true
    def translate_event(_data, state), do: {[], state, []}

    @impl true
    def handle_exit_error(_exit_code, state), do: {[], state}

    @impl true
    def handle_stream_end(state), do: {[], state}
  end

  test "cancel stops runner" do
    Application.put_env(:agent_core, :cli_cancel_grace_ms, 500)

    {:ok, pid} =
      DummyRunner.start_link(prompt: "", cwd: File.cwd!(), timeout: 60_000, owner: self())

    stream = DummyRunner.stream(pid)
    ref = Process.monitor(pid)

    DummyRunner.cancel(pid, :test_cancel)

    events = AgentCore.EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:canceled, :test_cancel} -> true
             _ -> false
           end)

    assert_receive {:cli_term, _os_pid}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end
end
