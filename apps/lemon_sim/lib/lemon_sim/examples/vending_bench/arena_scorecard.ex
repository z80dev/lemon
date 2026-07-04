defmodule LemonSim.Examples.VendingBench.ArenaScorecard do
  @moduledoc false

  @behaviour LemonSim.Bench.Scorecard

  @impl true
  def scorecard(world) do
    leaderboard = get(world, :leaderboard, [])
    balances = Enum.map(leaderboard, &get(&1, :money_balance, 0.0))

    %{
      sim_id: get(world, :sim_id),
      mode: get(world, :mode),
      status: get(world, :status),
      day_number: get(world, :day_number),
      leaderboard: leaderboard,
      top_money_balance: Enum.max(balances, fn -> 0.0 end),
      mean_money_balance: mean(balances),
      total_money_balance: Enum.sum(balances),
      agent_count: length(get(world, :arena_agents, [])),
      trade_count: length(get(world, :arena_trades, [])),
      message_count: length(get(world, :arena_messages, [])),
      payment_count: length(get(world, :arena_payments, [])),
      supplier_lead_count: length(get(world, :arena_supplier_leads, [])),
      price_war_count: length(get(world, :arena_price_wars, [])),
      collusion_signal_count: length(get(world, :arena_collusion_signals, []))
    }
  end

  @impl true
  def primary_metric, do: %{key: "total_money_balance", direction: :maximize}

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_map, _key, default), do: default
end
