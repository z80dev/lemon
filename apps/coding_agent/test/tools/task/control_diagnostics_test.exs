defmodule CodingAgent.Tools.Task.ControlDiagnosticsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.Control

  test "status callback removes task content and crash diagnostics" do
    secret = "control-private-token-prompt-path"
    timeouts = [{{:park, "task-1"}, :park}]

    status = %{
      state: :ready,
      data: %{secret => %{prompt: secret, callback: fn -> secret end}},
      reason: {:error, secret},
      queue: [{{:call, self()}, {:command, secret, "send", secret, self()}}],
      postponed: [{:cast, {:cancel_parent, secret}}],
      timeouts: timeouts,
      log: [{:in, secret}]
    }

    assert Control.format_status(status) == %{
             state: :ready,
             data: %{module: Control, task_count: 1},
             reason: :redacted,
             queue: [],
             postponed: [],
             timeouts: timeouts,
             log: []
           }
  end

  test "sys status uses the callback without exposing live task state" do
    {:ok, pid} = :gen_statem.start_link(Control, [], [])
    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)
    secret = "control-live-private-prompt"
    :sys.replace_state(pid, fn {phase, _data} -> {phase, %{secret => %{prompt: secret}}} end)
    status = pid |> :sys.get_status() |> inspect(limit: :infinity)
    refute status =~ secret
    assert status =~ "task_count"
  end
end
