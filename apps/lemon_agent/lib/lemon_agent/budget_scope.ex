defmodule LemonAgent.BudgetScope do
  @moduledoc """
  Serializes enforcement-only usage for a native session and its descendants.

  Checks and cost-cap queries read protected ETS snapshots directly, including
  ancestor snapshots, without synchronous calls into the scope tree. Each scope
  owns its table; its Registry entry and counters disappear when it exits.
  Updates and cumulative propagation remain serialized and acknowledged.

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

  def check(pid, projected) do
    {budget, parent} = snapshot(pid)
    Budget.check(budget, projected) || check(parent, projected)
  end

  def cost_capped?(nil), do: false
  def cost_capped?({pid, _run}), do: cost_capped?(pid)

  def cost_capped?(pid) do
    {budget, parent} = snapshot(pid)

    Enum.any?(
      [:max_run_cost_usd, :max_session_cost_usd],
      &is_number(Map.get(budget.limits, &1))
    ) or cost_capped?(parent)
  end

  def update(pid, budget), do: GenServer.call(pid, {:own, budget})
  def report(nil, _id, _usage), do: :ok
  def report({pid, run}, id, usage), do: GenServer.call(pid, {:child, run, id, usage})

  @impl true
  def init(opts) do
    Process.monitor(Keyword.fetch!(opts, :owner))

    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    {:ok, _} = Registry.register(LemonAgent.AgentRegistry, {__MODULE__, self()}, table)

    state = %{
      own: Budget.new(Keyword.fetch!(opts, :limits), Keyword.get(opts, :usage)),
      children: %{},
      child_usage: Budget.normalize_usage(Keyword.get(opts, :child_usage)),
      child_run_usage: Budget.normalize_usage(nil),
      run: make_ref(),
      parent: Keyword.get(opts, :parent),
      id: Keyword.fetch!(opts, :id),
      owner: Keyword.fetch!(opts, :owner),
      table: table
    }

    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:begin_run, _from, state) do
    state = %{
      state
      | run: make_ref(),
        child_run_usage: Budget.normalize_usage(nil),
        own: %{state.own | run_usage: Budget.normalize_usage(nil)}
    }

    publish(state)
    {:reply, :ok, state}
  end

  def handle_call(:attachment, _from, state), do: {:reply, {self(), state.run}, state}

  def handle_call({:own, budget}, _from, state) do
    state = %{state | own: budget}
    publish(state)
    propagate(state)
    {:reply, :ok, state}
  end

  def handle_call({:child, run, id, usage}, _from, state) do
    usage = Budget.normalize_usage(usage)
    previous = Map.get(state.children, id, Budget.normalize_usage(nil))

    delta = %{
      tokens: delta(usage.tokens, previous.tokens),
      cost_usd: delta(usage.cost_usd, previous.cost_usd)
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

    publish(state)
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

  # Each scope owns its row; Registry's ETS-backed lookup locates it without
  # messaging any scope. Deep checks never enter an ancestor's mailbox.
  defp snapshot(pid) do
    [{^pid, table}] = Registry.lookup(LemonAgent.AgentRegistry, {__MODULE__, pid})
    [{:budget, budget, parent}] = :ets.lookup(table, :budget)
    {budget, parent}
  end

  defp publish(state) do
    :ets.insert(state.table, {:budget, inclusive(state), state.parent})
  end

  defp delta(current, previous) when is_number(current) and is_number(previous),
    do: max(current - previous, 0)

  defp delta(_current, _previous), do: nil
end
