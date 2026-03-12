defmodule LemonSim.Examples.StockMarket.Performance do
  @moduledoc """
  Objective performance summary for Stock Market Arena.

  The benchmark emphasis is private-information usage, public signaling,
  and directional trading quality under social pressure.
  """

  import LemonSim.GameHelpers

  alias LemonSim.Examples.StockMarket.Market

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    stocks = get(world, :stocks, %{})
    winner = get(world, :winner)

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        final_value = Market.portfolio_value(info, stocks)

        {player_id,
         %{
           name: get(info, :name, player_id),
           model: get(info, :model),
           won: winner == player_id,
           final_value: final_value,
           final_reputation: get(info, :reputation, Market.initial_reputation()),
           return_pct:
             Float.round((final_value - Market.initial_cash()) / Market.initial_cash() * 100, 2),
           trades_executed: 0,
           profitable_trades: 0,
           short_trades: 0,
           market_calls_made: 0,
           accurate_calls: 0,
           whispers_sent: 0
         }}
      end)
      |> apply_trade_history(players, stocks)
      |> apply_market_call_history(
        get(world, :market_call_history, []),
        get(world, :round_summaries, [])
      )
      |> apply_whisper_history(get(world, :whisper_history, []))

    %{
      benchmark_focus: "private-information trading, public signaling, and directional accuracy",
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_trade_history(metrics, players, stocks) do
    final_prices =
      Enum.into(Market.stock_names(), %{}, fn ticker ->
        {ticker, Market.get_stock_price(stocks, ticker)}
      end)

    Enum.reduce(players, metrics, fn {player_id, info}, acc ->
      trades = get(info, :trade_history, [])

      Enum.reduce(trades, acc, fn trade, trade_acc ->
        trade_acc
        |> update_player(player_id, &Map.update!(&1, :trades_executed, fn count -> count + 1 end))
        |> maybe_increment(player_id, get(trade, :action) in ["short", "cover"], :short_trades)
        |> maybe_mark_profitable_trade(player_id, trade, final_prices)
      end)
    end)
  end

  defp apply_market_call_history(metrics, history, round_summaries) do
    round_changes =
      Enum.into(round_summaries, %{}, fn summary ->
        {get(summary, :round), get(summary, :price_changes, %{})}
      end)

    Enum.reduce(history, metrics, fn call, acc ->
      player_id = get(call, :player)
      round = get(call, :round)
      stock = get(call, :stock)
      stance = get(call, :stance)

      stock_change =
        round_changes
        |> Map.get(round, %{})
        |> Map.get(stock, %{})
        |> get(:change, 0)

      accurate? =
        case stance do
          "bullish" -> stock_change > 0
          "bearish" -> stock_change < 0
          _ -> false
        end

      acc
      |> update_player(player_id, &Map.update!(&1, :market_calls_made, fn count -> count + 1 end))
      |> maybe_increment(player_id, accurate?, :accurate_calls)
    end)
  end

  defp apply_whisper_history(metrics, whisper_history) do
    Enum.reduce(whisper_history, metrics, fn whisper, acc ->
      update_player(
        acc,
        get(whisper, :from),
        &Map.update!(&1, :whispers_sent, fn count -> count + 1 end)
      )
    end)
  end

  defp maybe_mark_profitable_trade(metrics, player_id, trade, final_prices) do
    stock = get(trade, :stock)
    final_price = Map.get(final_prices, stock, get(trade, :price, 0))
    trade_price = get(trade, :price, 0)

    profitable? =
      case get(trade, :action) do
        "buy" -> final_price > trade_price
        "sell" -> final_price < trade_price
        "short" -> final_price < trade_price
        "cover" -> final_price > trade_price
        _ -> false
      end

    maybe_increment(metrics, player_id, profitable?, :profitable_trades)
  end

  defp maybe_increment(metrics, _player_id, false, _key), do: metrics

  defp maybe_increment(metrics, player_id, true, key) do
    update_player(metrics, player_id, &Map.update!(&1, key, fn count -> count + 1 end))
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
         total_return_pct: Float.round(Enum.sum(Enum.map(metrics, &get(&1, :return_pct, 0))), 2),
         accurate_calls: Enum.sum(Enum.map(metrics, &get(&1, :accurate_calls, 0))),
         profitable_trades: Enum.sum(Enum.map(metrics, &get(&1, :profitable_trades, 0))),
         short_trades: Enum.sum(Enum.map(metrics, &get(&1, :short_trades, 0)))
       }}
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
