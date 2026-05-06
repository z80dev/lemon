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
      assert "agent_loop_learning_trace_contract" in names
      assert "agent_loop_memory_trace_contract" in names
      assert "agent_loop_async_join_trace_contract" in names
      assert "agent_loop_parallel_join_trace_contract" in names
      assert "agent_loop_delegation_artifact_trace_contract" in names
      assert "delegation_toolset_contract" in names
    end

    test "live-model checks are opt in", %{tmp_dir: tmp_dir} do
      default_report = Harness.run(cwd: tmp_dir, iterations: 2)
      default_names = Enum.map(default_report.results, & &1.name)

      refute "live_model_memory_trace_contract" in default_names
      refute "live_model_skill_learning_contract" in default_names
      refute "live_model_skill_curator_contract" in default_names
      refute "live_model_cron_block_contract" in default_names
      refute "live_model_parallel_delegation_contract" in default_names
      refute "live_model_delegation_artifact_contract" in default_names
      refute "live_model_leaf_toolset_contract" in default_names

      live_report = Harness.run(cwd: tmp_dir, iterations: 2, live_model: true, live_api_key: "")
      live_names = Enum.map(live_report.results, & &1.name)

      assert "live_model_memory_trace_contract" in live_names
      assert "live_model_skill_learning_contract" in live_names
      assert "live_model_skill_curator_contract" in live_names
      assert "live_model_cron_block_contract" in live_names
      assert "live_model_parallel_delegation_contract" in live_names
      assert "live_model_delegation_artifact_contract" in live_names
      assert "live_model_leaf_toolset_contract" in live_names
    end

    test "live-model memory eval reports missing credentials without provider access", %{
      tmp_dir: tmp_dir
    } do
      result = Harness.live_model_memory_trace_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_memory_trace_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end

    test "live-model skill eval reports missing credentials without provider access", %{
      tmp_dir: tmp_dir
    } do
      result = Harness.live_model_skill_learning_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_skill_learning_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end

    test "live-model curator eval reports missing credentials without provider access", %{
      tmp_dir: tmp_dir
    } do
      result = Harness.live_model_skill_curator_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_skill_curator_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end

    test "live-model cron block eval reports missing credentials without provider access", %{
      tmp_dir: tmp_dir
    } do
      result = Harness.live_model_cron_block_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_cron_block_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end

    test "live-model parallel delegation eval reports missing credentials without provider access",
         %{
           tmp_dir: tmp_dir
         } do
      result = Harness.live_model_parallel_delegation_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_parallel_delegation_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end

    test "live-model delegation artifact eval reports missing credentials without provider access",
         %{
           tmp_dir: tmp_dir
         } do
      result = Harness.live_model_delegation_artifact_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_delegation_artifact_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end

    test "live-model leaf toolset eval reports missing credentials without provider access",
         %{
           tmp_dir: tmp_dir
         } do
      result = Harness.live_model_leaf_toolset_contract_eval(tmp_dir, live_api_key: "")

      assert result.name == "live_model_leaf_toolset_contract"
      assert result.status == :fail
      assert result.details.reason =~ "LEMON_EVAL_API_KEY"
    end
  end
end
