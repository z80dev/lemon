defmodule LemonEvals.HarnessContractTest do
  use ExUnit.Case, async: true

  alias LemonEvals.Harness

  @moduletag :tmp_dir

  describe "run/1" do
    test "live-model checks are opt in", %{tmp_dir: tmp_dir} do
      default_report = Harness.run(cwd: tmp_dir, iterations: 2)
      default_names = Enum.map(default_report.results, & &1.name)

      refute "live_model_memory_trace_contract" in default_names
      refute "live_model_remember_contract" in default_names
      refute "live_model_workspace_memory_file_contract" in default_names
      refute "live_model_skill_learning_contract" in default_names
      refute "live_model_relevant_skill_usage_contract" in default_names
      refute "live_model_skill_curator_contract" in default_names
      refute "live_model_cron_block_contract" in default_names
      refute "live_model_untrusted_prompt_injection_contract" in default_names
      refute "live_model_parallel_delegation_contract" in default_names
      refute "live_model_delegation_artifact_contract" in default_names
      refute "live_model_leaf_toolset_contract" in default_names
      refute "live_model_coding_repair_contract" in default_names

      live_report = Harness.run(cwd: tmp_dir, iterations: 2, live_model: true, live_api_key: "")
      live_names = Enum.map(live_report.results, & &1.name)

      assert "live_model_memory_trace_contract" in live_names
      assert "live_model_remember_contract" in live_names
      assert "live_model_workspace_memory_file_contract" in live_names
      assert "live_model_skill_learning_contract" in live_names
      assert "live_model_relevant_skill_usage_contract" in live_names
      assert "live_model_skill_curator_contract" in live_names
      assert "live_model_cron_block_contract" in live_names
      assert "live_model_untrusted_prompt_injection_contract" in live_names
      assert "live_model_parallel_delegation_contract" in live_names
      assert "live_model_delegation_artifact_contract" in live_names
      assert "live_model_leaf_toolset_contract" in live_names
      assert "live_model_coding_repair_contract" in live_names
    end

    test "live-model evals report missing credentials without provider access", %{
      tmp_dir: tmp_dir
    } do
      for contract <- [
            :live_model_memory_trace_contract,
            :live_model_remember_contract,
            :live_model_workspace_memory_file_contract,
            :live_model_skill_learning_contract,
            :live_model_relevant_skill_usage_contract,
            :live_model_skill_curator_contract,
            :live_model_cron_block_contract,
            :live_model_untrusted_prompt_injection_contract,
            :live_model_parallel_delegation_contract,
            :live_model_delegation_artifact_contract,
            :live_model_leaf_toolset_contract,
            :live_model_coding_repair_contract
          ] do
        result = apply(Harness, :"#{contract}_eval", [tmp_dir, [live_api_key: ""]])
        assert result.name == Atom.to_string(contract)
        assert result.status == :fail, "#{contract} must reject missing credentials"
        assert result.details.reason =~ "LEMON_EVAL_API_KEY"
      end
    end
  end
end
