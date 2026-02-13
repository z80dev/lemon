defmodule CodingAgent.Evals.HarnessTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Evals.Harness

  test "eval harness passes all baseline checks" do
    report = Harness.run(cwd: File.cwd!(), iterations: 10)

    assert report.summary.failed == 0

    assert Enum.map(report.results, & &1.name) == [
             "deterministic_contract",
             "statistical_stability",
             "read_edit_workflow"
           ]
  end
end
