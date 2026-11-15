defmodule CodingAgent.Tools.BashSandbox606Test do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash

  test "sandbox refuses PTY instead of executing through the local or client executor" do
    parent = self()

    opts = [
      tool_policy: %{sandbox: true},
      acp_client_terminal: true,
      before_start: fn -> send(parent, :unexpected_host_launch) end
    ]

    assert {:error, "pty is not supported by the enforced Docker sandbox"} =
             Bash.execute(
               "sandbox-test",
               %{"command" => "echo should-not-run", "pty" => true},
               nil,
               nil,
               File.cwd!(),
               opts
             )

    refute_received :unexpected_host_launch
  end

  test "malformed sandbox policy is rejected before any shell execution" do
    result =
      Bash.execute(
        "invalid-policy-test",
        %{"command" => "echo should-not-run"},
        nil,
        nil,
        File.cwd!(), tool_policy: %{sandbox: "false"})

    assert result == {:error, "Invalid terminal tool policy"}
  end
end
