defmodule LemonAgent.BudgetScopeTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{Budget, BudgetScope}

  defp scope(limits, opts \\ []) do
    {:ok, pid} =
      BudgetScope.start_link(Keyword.merge([limits: limits, id: make_ref(), owner: self()], opts))

    pid
  end

  test "live and repeated completion reports charge descendants exactly once" do
    parent = scope(%{max_run_cost_usd: 1.0})
    attachment = BudgetScope.attachment(parent)
    child = scope(%{}, parent: attachment, id: :child)
    assert Budget.unpriced_warning(%{scope: child}, %{cost: nil}) =~ "no known catalog price"
    usage = %{tokens: 10, cost_usd: 1.0}

    :ok =
      BudgetScope.update(child, %{Budget.new(%{}, nil) | run_usage: usage, session_usage: usage})

    assert %{scope: :run, used: 1.0} = BudgetScope.check(parent)
    assert %{scope: :run, used: 1.0} = BudgetScope.check(child)
    :ok = BudgetScope.report(attachment, :child, usage)
    :ok = BudgetScope.report(attachment, :child, %{tokens: 5, cost_usd: 0.5})
    assert %{run_usage: ^usage, session_usage: ^usage} = BudgetScope.check(parent)
  end

  test "grandchildren count once and late reports do not charge a new run" do
    parent = scope(%{max_run_tokens: 10, max_session_tokens: 20})
    attachment = BudgetScope.attachment(parent)
    child = scope(%{}, parent: attachment, id: :child)
    grandchild = scope(%{}, parent: BudgetScope.attachment(child), id: :grandchild)
    usage = %{tokens: 10, cost_usd: 0.25}

    :ok =
      BudgetScope.update(grandchild, %{
        Budget.new(%{}, nil)
        | run_usage: usage,
          session_usage: usage
      })

    assert %{scope: :run, used: 10} = BudgetScope.check(parent)
    :ok = BudgetScope.begin_run(parent)
    assert BudgetScope.check(parent) == nil
    :ok = BudgetScope.report(attachment, :child, %{tokens: 20, cost_usd: 0.5})
    assert %{scope: :session, used: 20, run_usage: %{tokens: 0}} = BudgetScope.check(parent)
  end

  test "parent and child spend share the same inclusive run cap" do
    parent = scope(%{max_run_cost_usd: 1.0})
    own = %{tokens: 5, cost_usd: 0.25}

    :ok =
      BudgetScope.update(parent, %{
        Budget.new(%{}, nil)
        | limits: %{max_run_cost_usd: 1.0},
          run_usage: own,
          session_usage: own
      })

    assert BudgetScope.check(parent) == nil

    :ok =
      BudgetScope.report(BudgetScope.attachment(parent), :child, %{tokens: 10, cost_usd: 0.75})

    assert %{used: 1.0, run_usage: %{tokens: 15}} = BudgetScope.check(parent)
  end

  test "restored descendant totals enforce session caps without becoming own usage" do
    parent = scope(%{max_session_cost_usd: 1.0}, child_usage: %{cost_usd: 1.0})

    assert %{scope: :session, run_usage: %{cost_usd: own_cost}, used: 1.0} =
             BudgetScope.check(parent)

    assert own_cost == 0.0
  end
end
