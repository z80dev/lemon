defmodule LemonSim.Examples.Diplomacy.Performance do
  @moduledoc """
  Objective performance summary for Diplomacy-lite runs.

  The benchmark emphasis is negotiation throughput, order discipline,
  support coordination, and territory conversion.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    final_territories = territory_counts(get(world, :territories, %{}))

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        {player_id,
         %{
           faction: get(info, :faction, player_id),
           model: get(info, :model),
           won: winner == player_id,
           messages_sent: 0,
           orders_submitted: 0,
           support_orders: 0,
           territories_captured: 0,
           final_territories: Map.get(final_territories, player_id, 0)
         }}
      end)
      |> apply_message_history(get(world, :message_history, []))
      |> apply_order_history(get(world, :order_history, []))
      |> apply_capture_history(get(world, :capture_history, []))

    %{
      benchmark_focus: "negotiation throughput, support coordination, and territory conversion",
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_message_history(metrics, message_history) do
    Enum.reduce(message_history, metrics, fn record, acc ->
      player = get(record, :from)
      update_player(acc, player, &Map.update!(&1, :messages_sent, fn count -> count + 1 end))
    end)
  end

  defp apply_order_history(metrics, order_history) do
    Enum.reduce(order_history, metrics, fn record, acc ->
      player = get(record, :player)
      orders = get(record, :orders, %{})

      support_orders =
        orders
        |> Map.values()
        |> Enum.count(fn order ->
          Map.get(order, :order_type, Map.get(order, "order_type")) == "support"
        end)

      acc
      |> update_player(player, &Map.update!(&1, :orders_submitted, fn count -> count + 1 end))
      |> update_player(
        player,
        &Map.update!(&1, :support_orders, fn count -> count + support_orders end)
      )
    end)
  end

  defp apply_capture_history(metrics, capture_history) do
    Enum.reduce(capture_history, metrics, fn record, acc ->
      player = get(record, :attacker)

      update_player(
        acc,
        player,
        &Map.update!(&1, :territories_captured, fn count -> count + 1 end)
      )
    end)
  end

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn {_player_id, metrics} -> get(metrics, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics = Enum.map(entries, fn {_player_id, item} -> item end)

      {model,
       %{
         seats: length(metrics),
         wins: Enum.count(metrics, &get(&1, :won, false)),
         messages_sent: Enum.sum(Enum.map(metrics, &get(&1, :messages_sent, 0))),
         support_orders: Enum.sum(Enum.map(metrics, &get(&1, :support_orders, 0))),
         territories_captured: Enum.sum(Enum.map(metrics, &get(&1, :territories_captured, 0))),
         final_territories: Enum.sum(Enum.map(metrics, &get(&1, :final_territories, 0)))
       }}
    end)
  end

  defp territory_counts(territories) do
    Enum.reduce(territories, %{}, fn {_territory, info}, acc ->
      owner = get(info, :owner)

      if owner do
        Map.update(acc, owner, 1, &(&1 + 1))
      else
        acc
      end
    end)
  end

  defp update_player(metrics, nil, _updater), do: metrics

  defp update_player(metrics, player_id, updater) do
    case Map.fetch(metrics, player_id) do
      {:ok, item} -> Map.put(metrics, player_id, updater.(item))
      :error -> metrics
    end
  end
end
