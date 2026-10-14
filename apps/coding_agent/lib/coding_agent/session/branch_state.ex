defmodule CodingAgent.Session.BranchState do
  @moduledoc """
  The single restoration seam for journal-derived session state.

  Startup (fresh, resumed or a forked file), rewind, tree navigation and reset
  select a branch and then call `restore/1`, which re-derives plan mode and the
  approved plan (`CodingAgent.Session.Planning`) and the todo list
  (`CodingAgent.Session.Todos`) from that branch. It also advances the branch
  generation, so todo writes prepared against the previous selection fail.

  Only semantic branch state lives here. Actual spend (`BudgetLedger`), the
  session's current tool policy and approvals, runtime handles and external
  effects follow their own lifecycles: restoring a branch never refunds spend,
  reruns tools or restores revoked authority.
  """

  alias CodingAgent.Session.{Planning, Todos}

  @spec restore(map()) :: map()
  def restore(state) do
    %{state | branch_generation: (state.branch_generation || 0) + 1}
    |> Planning.refresh()
    |> Todos.sync()
  end
end
