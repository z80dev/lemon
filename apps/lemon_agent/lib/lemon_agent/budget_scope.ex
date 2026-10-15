defmodule LemonAgent.BudgetScope do
  @moduledoc """
  Serializes enforcement-only usage for a native session and its descendants.

  Provider usage events and billing records remain local to each session. Child
  reports are cumulative, keyed by child identity, so completion can safely repeat
  the last live report. A child retains its originating run reference: late usage
  charges the session, but never a subsequent parent run.
  """
  use GenServer

  alias LemonAgent.Budget

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def begin_run(pid), do: GenServer.call(pid, :begin_run)
  def attachment(pid), do: GenServer.call(pid, :attachment)
  def check(scope, projected \\ %{tokens: 0, cost_usd: 0.0})
  def check(nil, _projected), do: nil
  def check({pid, _run}, projected), do: check(pid, projected)
  def check(pid, projected), do: GenServer.call(pid, {:check, projected})
  def cost_capped?(nil), do: false
  def cost_capped?({pid, _run}), do: cost_capped?(pid)
  def cost_capped?(pid), do: GenServer.call(pid, :cost_capped)
  def update(pid, budget), do: GenServer.call(pid, {:own, budget})
  def report(nil, _id, _usage), do: :ok
  def report({pid, run}, id, usage), do: GenServer.call(pid, {:child, run, id, usage})

  @impl true
  def init(opts) do
    Process.monitor(Keyword.fetch!(opts, :owner))

    {:ok,
     %{
       own: Budget.new(Keyword.fetch!(opts, :limits), Keyword.get(opts, :usage)),
       children: %{},
       child_usage: Budget.normalize_usage(Keyword.get(opts, :child_usage)),
       child_run_usage: Budget.normalize_usage(nil),
       run: make_ref(),
       parent: Keyword.get(opts, :parent),
       id: Keyword.fetch!(opts, :id),
       owner: Keyword.fetch!(opts, :owner)
     }}
  end

  @impl true
  def handle_call(:begin_run, _from, state) do
    state = %{
      state
      | run: make_ref(),
        child_run_usage: Budget.normalize_usage(nil),
        own: %{state.own | run_usage: Budget.normalize_usage(nil)}
    }

    {:reply, :ok, state}
  end

  def handle_call(:attachment, _from, state), do: {:reply, {self(), state.run}, state}

  def handle_call({:check, projected}, _from, state) do
    {:reply, Budget.check(inclusive(state), projected) || check(state.parent, projected), state}
  end

  def handle_call(:cost_capped, _from, state) do
    own_cap =
      Enum.any?(
        [:max_run_cost_usd, :max_session_cost_usd],
        &is_number(Map.get(state.own.limits, &1))
      )

    {:reply, own_cap or cost_capped?(state.parent), state}
  end

  def handle_call({:own, budget}, _from, state) do
    state = %{state | own: budget}
    propagate(state)
    {:reply, :ok, state}
  end

  def handle_call({:child, run, id, usage}, _from, state) do
    usage = Budget.normalize_usage(usage)
    previous = Map.get(state.children, id, Budget.normalize_usage(nil))

    delta = %{
      tokens: max(usage.tokens - previous.tokens, 0),
      cost_usd: max(usage.cost_usd - previous.cost_usd, 0.0)
    }

    latest = Budget.add_usage(previous, delta)

    state = %{
      state
      | children: Map.put(state.children, id, latest),
        child_usage: Budget.add_usage(state.child_usage, delta),
        child_run_usage:
          if(run == state.run,
            do: Budget.add_usage(state.child_run_usage, delta),
            else: state.child_run_usage
          )
    }

    send(state.owner, {:subagent_budget_usage, state.child_usage})
    propagate(state)
    {:reply, :ok, state}
  end

  defp inclusive(state) do
    %{
      state.own
      | run_usage: Budget.add_usage(state.own.run_usage, state.child_run_usage),
        session_usage: Budget.add_usage(state.own.session_usage, state.child_usage)
    }
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  defp propagate(state), do: report(state.parent, state.id, inclusive(state).session_usage)
end
