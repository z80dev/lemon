defmodule CodingAgent.Tools.Task.ControlDiagnosticsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.Control

  test "status callback removes task content and crash diagnostics" do
    secret = "control-private-token-prompt-path"

    status = %{
      state: %{secret => %{prompt: secret, callback: fn -> secret end}},
      message: {:command, secret, "send", secret, self()},
      reason: {:error, secret},
      log: [{:in, secret}]
    }

    assert Control.format_status(status) == %{
             state: %{module: Control, task_count: 1},
             message: :redacted,
             reason: :redacted,
             log: []
           }
  end

  test "sys status uses the callback without exposing live task state" do
    {:ok, pid} = GenServer.start_link(Control, [])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    secret = "control-live-private-prompt"
    :sys.replace_state(pid, fn _ -> %{secret => %{prompt: secret}} end)
    status = pid |> :sys.get_status() |> inspect(limit: :infinity)
    refute status =~ secret
    assert status =~ "task_count"
  end
end
