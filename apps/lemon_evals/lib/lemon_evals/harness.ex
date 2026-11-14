defmodule LemonEvals.Harness do
  @moduledoc """
  Lightweight quality evaluation harness for coding workflows.

  The suite runs three evaluation classes:
  - deterministic contract checks
  - statistical stability checks
  - workflow scenario checks

  `run/1` orchestrates the suite; individual non-live checks live in their
  owning modules. Live-model checks are also exposed here for callers.

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

  @evals [
    {Foundational, :deterministic_contract_eval, 1},
    {Foundational, :statistical_stability_eval, 2},
    {Foundational, :read_edit_workflow_eval, 1},
    {MemoryAndSkills, :memory_scope_contract_eval, 1},
    {MemoryAndSkills, :remember_contract_eval, 1},
    {MemoryAndSkills, :auto_skill_prompt_contract_eval, 1},
    {MemoryAndSkills, :dedicated_tool_preference_contract_eval, 1},
    {MemoryAndSkills, :skill_curator_behavior_contract_eval, 1},
    {MemoryAndSkills, :learning_tool_trace_contract_eval, 1},
    {MemoryAndSkills, :tool_use_claim_contract_eval, 1},
    {MemoryAndSkills, :untrusted_prompt_injection_contract_eval, 1},
    {AgentLoop, :agent_loop_learning_trace_contract_eval, 1},
    {AgentLoop, :agent_loop_skill_refinement_trace_contract_eval, 1},
    {AgentLoop, :agent_loop_memory_trace_contract_eval, 1},
    {AgentLoop, :agent_loop_workspace_memory_file_contract_eval, 1},
    {AgentLoop, :agent_loop_workspace_memory_update_contract_eval, 1},
    {AgentLoop, :agent_loop_async_join_trace_contract_eval, 1},
    {AgentLoop, :agent_loop_parallel_join_trace_contract_eval, 1},
    {AgentLoop, :agent_loop_delegation_artifact_trace_contract_eval, 1},
    {AgentLoop, :delegation_toolset_contract_eval, 1}
  ]

  @spec run(keyword()) :: run_report()
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    iterations = Keyword.get(opts, :iterations, 25)

    if not is_integer(iterations) or iterations <= 0 do
      raise ArgumentError, "iterations must be a positive integer"
    end

    results =
      Enum.map(@evals, fn {module, function, arity} ->
        args = if arity == 2, do: [cwd, iterations], else: [cwd]
        apply(module, function, args)
      end) ++ LiveModel.results(cwd, opts)

    passed = Enum.count(results, &(&1.status == :pass))
    failed = Enum.count(results, &(&1.status == :fail))

    %{
      summary: %{passed: passed, failed: failed},
      results: results
    }
  end

  for contract <- LiveModel.contracts() do
    function = :"#{contract}_eval"

    @spec unquote(function)(String.t(), keyword()) :: eval_result()
    defdelegate unquote(function)(cwd, opts \\ []), to: LiveModel
  end

  @spec live_model_api_key(keyword()) :: String.t() | nil
  defdelegate live_model_api_key(opts \\ []), to: LiveModel
end
