defmodule LemonEvals.Evals.FoundationalTest do
  use ExUnit.Case, async: false

  alias LemonEvals.Evals.Foundational

  describe "deterministic_contract_eval/1" do
    test "passes when the builtin tool registry has no gaps or duplicates" do
      result = Foundational.deterministic_contract_eval(File.cwd!())

      assert result.name == "deterministic_contract"
      assert result.status == :pass
      assert is_integer(result.details.tool_count)
      assert result.details.tool_count > 0
    end
  end

  describe "statistical_stability_eval/2" do
    test "passes when the tool name list is stable across iterations" do
      result = Foundational.statistical_stability_eval(File.cwd!(), 5)

      assert result == %{
               name: "statistical_stability",
               status: :pass,
               details: %{iterations: 5, baseline_size: result.details.baseline_size}
             }
    end
  end

  describe "read_edit_workflow_eval/1" do
    test "reads and edits a fixture file end to end" do
      result = Foundational.read_edit_workflow_eval(File.cwd!())

      assert result.name == "read_edit_workflow"
      assert result.status == :pass
      assert is_binary(result.details.file)
    end
  end
end
