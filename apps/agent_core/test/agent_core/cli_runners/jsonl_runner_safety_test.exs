defmodule AgentCore.CliRunners.JsonlRunnerSafetyTest do
  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.Types.{
    ResumeToken,
    StartedEvent
  }

  defmodule SlowRunner do
    @behaviour AgentCore.CliRunners.JsonlRunner

    @impl true
    def engine, do: "slow"

    @impl true
    def build_command(_prompt, _resume, _state), do: {"sleep", ["1"]}

    @impl true
    def init_state(_prompt, _resume), do: %{}

    @impl true
    def stdin_payload(_prompt, _resume, _state), do: nil

    @impl true
    def decode_line(_line), do: {:error, :noop}

    @impl true
    def translate_event(_data, state), do: {[], state, []}

    @impl true
    def handle_exit_error(_exit_code, state), do: {[], state}

    @impl true
    def handle_stream_end(state), do: {[], state}

    @impl true
    def env(_state), do: nil
  end

  defmodule ResumeRunner do
    @behaviour AgentCore.CliRunners.JsonlRunner

    @impl true
    def engine, do: "session"

    @impl true
    def build_command(_prompt, %ResumeToken{value: value}, _state) do
      {"bash", ["-c", "echo '{\"session\":\"#{value}\"}'"]}
    end

    @impl true
    def build_command(_prompt, _resume, _state) do
      {"bash", ["-c", "echo '{\"session\":\"new\"}'"]}
    end

    @impl true
    def init_state(_prompt, _resume), do: %{}

    @impl true
    def stdin_payload(_prompt, _resume, _state), do: nil

    @impl true
    def decode_line(line), do: Jason.decode(line)

    @impl true
    def translate_event(%{"session" => value}, state) do
      token = ResumeToken.new("session", value)
      event = StartedEvent.new("session", token)
      {[event], state, found_session: token}
    end

    @impl true
    def translate_event(_data, state), do: {[], state, []}

    @impl true
    def handle_exit_error(_exit_code, state), do: {[], state}

    @impl true
    def handle_stream_end(state), do: {[], state}

    @impl true
    def env(_state), do: nil
  end

  test "uses configured default timeout when timeout option is omitted" do
    previous = Application.get_env(:agent_core, :cli_timeout_ms, :__unset__)
    Application.put_env(:agent_core, :cli_timeout_ms, 50)

    on_exit(fn -> restore_env(:agent_core, :cli_timeout_ms, previous) end)

    {:ok, events} = JsonlRunner.run(SlowRunner, prompt: "ignored")

    assert Enum.any?(events, fn
             {:error, :timeout, _} -> true
             _ -> false
           end)
  end

  test "reclaims stale session locks owned by dead processes" do
    lock_table = AgentCore.CliRunners.JsonlRunner.SessionLocks
    ensure_lock_table(lock_table)

    stale_value = "stale-#{System.unique_integer([:positive])}"
    key = {"session", stale_value}

    owner = spawn(fn -> :ok end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 200

    :ets.insert(lock_table, {key, owner, System.monotonic_time(:millisecond) - 60_000})

    on_exit(fn ->
      if :ets.whereis(lock_table) != :undefined do
        :ets.delete(lock_table, key)
      end
    end)

    resume = ResumeToken.new("session", stale_value)

    {:ok, events} =
      JsonlRunner.run(ResumeRunner, prompt: "resume", resume: resume, timeout: 5_000)

    assert Enum.any?(events, fn
             {:cli_event, %StartedEvent{resume: %ResumeToken{value: ^stale_value}}} -> true
             _ -> false
           end)
  end

  defp ensure_lock_table(lock_table) do
    case :ets.whereis(lock_table) do
      :undefined ->
        :ets.new(lock_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  defp restore_env(app, key, :__unset__), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
