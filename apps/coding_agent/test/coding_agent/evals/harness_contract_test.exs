defmodule CodingAgent.Evals.HarnessContractTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Evals.Harness

  @moduletag :tmp_dir

  describe "run/1" do
    test "includes Hermes-style memory and skill contract checks", %{tmp_dir: tmp_dir} do
      report = Harness.run(cwd: tmp_dir, iterations: 2)
      names = Enum.map(report.results, & &1.name)

      assert "memory_scope_contract" in names
      assert "memory_topic_contract" in names
      assert "auto_skill_prompt_contract" in names
      assert "skill_curator_behavior_contract" in names
      assert "learning_tool_trace_contract" in names
      assert "tool_use_claim_contract" in names
    end
  end
end
