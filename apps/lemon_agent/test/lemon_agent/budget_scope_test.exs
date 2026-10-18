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

  test "projected descendant requests respect ancestor caps without recording estimates" do
    parent = scope(%{max_session_cost_usd: 1.0}, child_usage: %{cost_usd: 0.75})
    child = scope(%{}, parent: BudgetScope.attachment(parent))

    assert %{scope: :session, used: 0.75, message: message} =
             BudgetScope.check(child, %{tokens: 10, cost_usd: 0.5})

    assert message =~ "next request is projected to exceed"
    refute BudgetScope.check(child, %{tokens: 10, cost_usd: 0.25})
    refute BudgetScope.check(parent)
  end

  test "restored descendant totals enforce session caps without becoming own usage" do
    parent = scope(%{max_session_cost_usd: 1.0}, child_usage: %{cost_usd: 1.0})

    assert %{scope: :session, run_usage: %{cost_usd: own_cost}, used: 1.0} =
             BudgetScope.check(parent)

    assert own_cost == 0.0
  end

  test "unknown descendant dollars survive repeated and stale completion reports" do
    for {key, expected_scope} <- [
          {:max_run_cost_usd, :run},
          {:max_session_cost_usd, :session}
        ] do
      parent = scope(%{key => 1.0})
      attachment = BudgetScope.attachment(parent)
      child = scope(%{}, parent: attachment, id: :partial_child)
      usage = %{tokens: 130, cost_usd: nil}

      :ok =
        BudgetScope.update(child, %{
          Budget.new(%{}, nil)
          | run_usage: usage,
            session_usage: usage
        })

      for report <- [usage, usage, %{tokens: 100, cost_usd: 0.1}] do
        assert :ok = BudgetScope.report(attachment, :partial_child, report)

        assert %{
                 scope: ^expected_scope,
                 metric: :cost_usd,
                 used: nil,
                 session_usage: %{tokens: 130, cost_usd: nil}
               } = BudgetScope.check(parent)

        assert %{metric: :cost_usd, used: nil} = BudgetScope.check(child)
      end
    end
  end

  test "unknown descendant tokens fail closed without losing known dollar spend" do
    parent = scope(%{max_run_tokens: 10_000})
    attachment = BudgetScope.attachment(parent)
    assert :ok = BudgetScope.report(attachment, :child, %{tokens: 10, cost_usd: 0.1})
    assert :ok = BudgetScope.report(attachment, :child, %{tokens: nil, cost_usd: 0.2})
    assert :ok = BudgetScope.report(attachment, :child, %{tokens: 20, cost_usd: 0.3})

    assert %{metric: :tokens, used: nil, session_usage: %{cost_usd: cost}} =
             BudgetScope.check(parent)

    assert_in_delta cost, 0.3, 0.000001
  end

  test "unknown descendant spend persists across runs but late reports do not poison a new run" do
    parent = scope(%{max_run_cost_usd: 1.0, max_session_cost_usd: 2.0})
    previous_run = BudgetScope.attachment(parent)
    usage = %{tokens: 130, cost_usd: nil}
    assert :ok = BudgetScope.report(previous_run, :child, usage)
    assert %{scope: :run, used: nil} = BudgetScope.check(parent)
    assert :ok = BudgetScope.begin_run(parent)
    assert :ok = BudgetScope.report(previous_run, :child, usage)

    assert %{scope: :session, used: nil, run_usage: %{tokens: 0, cost_usd: +0.0}} =
             BudgetScope.check(parent)
  end

  test "unknown projections fail closed at ancestor caps without recording usage" do
    parent = scope(%{max_session_cost_usd: 1.0})
    child = scope(%{}, parent: BudgetScope.attachment(parent))

    assert %{scope: :session, used: +0.0, metric: :cost_usd} =
             BudgetScope.check(child, %{tokens: 10, cost_usd: nil})

    refute BudgetScope.check(parent)
    refute BudgetScope.check(child)

    uncapped = scope(%{})

    assert :ok =
             BudgetScope.report(BudgetScope.attachment(uncapped), :child, %{
               tokens: nil,
               cost_usd: nil
             })

    refute BudgetScope.check(uncapped, %{tokens: nil, cost_usd: nil})
  end

  test "restored unknown descendant totals enforce session caps" do
    parent =
      scope(%{max_session_cost_usd: 1.0},
        child_usage: %{"tokens" => 130, "cost_usd" => nil}
      )

    assert %{scope: :session, used: nil, run_usage: %{cost_usd: +0.0}} =
             BudgetScope.check(parent)
  end
end
