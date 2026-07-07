defmodule LemonEvals.Harness do
  @moduledoc """
  Lightweight quality evaluation harness for coding workflows.

  The suite runs three evaluation classes:
  - deterministic contract checks
  - statistical stability checks
  - workflow scenario checks

  This module is a thin facade: `run/1` orchestrates the eval suite, and
  every individual `*_eval` function is delegated to the module that owns
  that concern so external callers and tests keep working unchanged.

    * `LemonEvals.Evals.Foundational` - deterministic/statistical/read-edit checks
    * `LemonEvals.Evals.MemoryAndSkills` - memory and skill contract checks
    * `LemonEvals.Evals.AgentLoop` - scripted agent-loop trace contracts
    * `LemonEvals.Evals.LiveModel` - opt-in live-model contract checks
    * `LemonEvals.Support` - shared test-support helpers used by the above
  """

  alias LemonEvals.Evals.{AgentLoop, Foundational, LiveModel, MemoryAndSkills}
  alias LemonEvals.Types

  @type eval_result :: Types.eval_result()
  @type run_report :: Types.run_report()

  @spec run(keyword()) :: run_report()
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    iterations = Keyword.get(opts, :iterations, 25)

    if not is_integer(iterations) or iterations <= 0 do
      raise ArgumentError, "iterations must be a positive integer"
    end

    results =
      [
        Foundational.deterministic_contract_eval(cwd),
        Foundational.statistical_stability_eval(cwd, iterations),
        Foundational.read_edit_workflow_eval(cwd),
        MemoryAndSkills.memory_scope_contract_eval(cwd),
        MemoryAndSkills.memory_topic_contract_eval(cwd),
        MemoryAndSkills.auto_skill_prompt_contract_eval(cwd),
        MemoryAndSkills.dedicated_tool_preference_contract_eval(cwd),
        MemoryAndSkills.skill_curator_behavior_contract_eval(cwd),
        MemoryAndSkills.learning_tool_trace_contract_eval(cwd),
        MemoryAndSkills.tool_use_claim_contract_eval(cwd),
        MemoryAndSkills.untrusted_prompt_injection_contract_eval(cwd),
        AgentLoop.agent_loop_learning_trace_contract_eval(cwd),
        AgentLoop.agent_loop_skill_refinement_trace_contract_eval(cwd),
        AgentLoop.agent_loop_memory_trace_contract_eval(cwd),
        AgentLoop.agent_loop_workspace_memory_file_contract_eval(cwd),
        AgentLoop.agent_loop_workspace_memory_update_contract_eval(cwd),
        AgentLoop.agent_loop_async_join_trace_contract_eval(cwd),
        AgentLoop.agent_loop_parallel_join_trace_contract_eval(cwd),
        AgentLoop.agent_loop_delegation_artifact_trace_contract_eval(cwd),
        AgentLoop.delegation_toolset_contract_eval(cwd)
      ] ++ LiveModel.results(cwd, opts)

    passed = Enum.count(results, &(&1.status == :pass))
    failed = Enum.count(results, &(&1.status == :fail))

    %{
      summary: %{passed: passed, failed: failed},
      results: results
    }
  end

  # -- LemonEvals.Evals.Foundational -----------------------------------------

  @spec deterministic_contract_eval(String.t()) :: eval_result()
  defdelegate deterministic_contract_eval(cwd), to: Foundational

  @spec statistical_stability_eval(String.t(), pos_integer()) :: eval_result()
  defdelegate statistical_stability_eval(cwd, iterations), to: Foundational

  @spec read_edit_workflow_eval(String.t()) :: eval_result()
  defdelegate read_edit_workflow_eval(cwd), to: Foundational

  # -- LemonEvals.Evals.MemoryAndSkills ---------------------------------------

  @spec memory_scope_contract_eval(String.t()) :: eval_result()
  defdelegate memory_scope_contract_eval(cwd), to: MemoryAndSkills

  @spec memory_topic_contract_eval(String.t()) :: eval_result()
  defdelegate memory_topic_contract_eval(cwd), to: MemoryAndSkills

  @spec auto_skill_prompt_contract_eval(String.t()) :: eval_result()
  defdelegate auto_skill_prompt_contract_eval(cwd), to: MemoryAndSkills

  @spec dedicated_tool_preference_contract_eval(String.t()) :: eval_result()
  defdelegate dedicated_tool_preference_contract_eval(cwd), to: MemoryAndSkills

  @spec skill_curator_behavior_contract_eval(String.t()) :: eval_result()
  defdelegate skill_curator_behavior_contract_eval(cwd), to: MemoryAndSkills

  @spec learning_tool_trace_contract_eval(String.t()) :: eval_result()
  defdelegate learning_tool_trace_contract_eval(cwd), to: MemoryAndSkills

  @spec tool_use_claim_contract_eval(String.t()) :: eval_result()
  defdelegate tool_use_claim_contract_eval(cwd), to: MemoryAndSkills

  @spec untrusted_prompt_injection_contract_eval(String.t()) :: eval_result()
  defdelegate untrusted_prompt_injection_contract_eval(cwd), to: MemoryAndSkills

  # -- LemonEvals.Evals.AgentLoop ---------------------------------------------

  @spec agent_loop_learning_trace_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_learning_trace_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_skill_refinement_trace_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_skill_refinement_trace_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_memory_trace_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_memory_trace_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_workspace_memory_file_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_workspace_memory_file_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_workspace_memory_update_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_workspace_memory_update_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_async_join_trace_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_async_join_trace_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_parallel_join_trace_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_parallel_join_trace_contract_eval(cwd), to: AgentLoop

  @spec agent_loop_delegation_artifact_trace_contract_eval(String.t()) :: eval_result()
  defdelegate agent_loop_delegation_artifact_trace_contract_eval(cwd), to: AgentLoop

  @spec delegation_toolset_contract_eval(String.t()) :: eval_result()
  defdelegate delegation_toolset_contract_eval(cwd), to: AgentLoop

  # -- LemonEvals.Evals.LiveModel ----------------------------------------------

  @spec live_model_memory_trace_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_memory_trace_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_memory_topic_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_memory_topic_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_workspace_memory_file_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_workspace_memory_file_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_skill_learning_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_skill_learning_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_relevant_skill_usage_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_relevant_skill_usage_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_skill_curator_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_skill_curator_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_cron_block_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_cron_block_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_untrusted_prompt_injection_contract_eval(String.t(), keyword()) ::
          eval_result()
  defdelegate live_model_untrusted_prompt_injection_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_parallel_delegation_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_parallel_delegation_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_delegation_artifact_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_delegation_artifact_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_leaf_toolset_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_leaf_toolset_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_coding_repair_contract_eval(String.t(), keyword()) :: eval_result()
  defdelegate live_model_coding_repair_contract_eval(cwd, opts \\ []), to: LiveModel

  @spec live_model_api_key(keyword()) :: String.t() | nil
  defdelegate live_model_api_key(opts \\ []), to: LiveModel
end
