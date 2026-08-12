defmodule CodingAgent.CliRunners.LemonSubagentContractTest do
  @moduledoc """
  Holds the in-process runner to the same contract the vendor CLIs meet.

  No `:run_probe`: starting this one runs a real agent turn against a real
  model, which the contract kit is explicitly not allowed to do.
  """

  use LemonPlatformTest.SubagentRunnerCase,
    async: false,
    runner: CodingAgent.CliRunners.LemonSubagent

  test "declares itself the tool-level alias, not a router-visible engine" do
    assert CodingAgent.CliRunners.LemonSubagent.id() == "internal"
    refute CodingAgent.CliRunners.LemonSubagent.routable?()
  end

  test "children of the in-process engine keep full tool access" do
    assert CodingAgent.CliRunners.LemonSubagent.default_policy() == :full_access
  end
end
