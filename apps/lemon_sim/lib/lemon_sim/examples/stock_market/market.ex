defmodule LemonSim.Examples.StockMarket.Market do
  @moduledoc """
  Market mechanics, player management, and price generation for Stock Market Arena.
  """

  import LemonSim.GameHelpers

  @stocks %{
    "NOVA" => %{
      initial_price: 50,
      volatility: 2.0,
      label: "AI infrastructure",
      sector: "technology"
    },
    "PULSE" => %{
      initial_price: 36,
      volatility: 2.4,
      label: "biotech moonshot",
      sector: "healthcare"
    },
    "SAFE" => %{initial_price: 20, volatility: 0.4, label: "government bonds", sector: "rates"},
    "TERRA" => %{
      initial_price: 30,
      volatility: 1.1,
      label: "commodities complex",
      sector: "materials"
    },
    "VISTA" => %{
      initial_price: 42,
      volatility: 1.5,
      label: "consumer platform",
      sector: "consumer"
    }
  }
  @player_names [
    "Alice",
    "Bram",
    "Cora",
    "Dane",
    "Esme",
    "Felix",
    "Gia",
    "Hugo",
    "Iris",
    "Jude",
    "Kira",
    "Lena",
    "Milo",
    "Nora",
    "Owen",
    "Pia"
  ]
  @bullish_words ~w(bullish buy long up rise upside rally strong breakout moon surge boom undervalued accumulate squeeze)
  @bearish_words ~w(bearish sell short down fall downside dump weak overvalued crash panic fade risk miss)
  @macro_regimes [
    {"risk-on", "speculative appetite is rising across the tape"},
    {"inflation scare", "rates and commodity chatter are dominating desks"},
    {"AI frenzy", "every conversation seems to come back to compute and automation"},
    {"consumer slowdown", "discretionary demand is getting questioned"},
    {"flight to safety", "defensive positioning is creeping into flow"}
  ]

  @initial_cash 10_000
  @initial_reputation 50
  @max_rounds 10
  @short_exposure_ratio 0.75

  @spec stock_config() :: map()
  def stock_config, do: @stocks

  @spec initial_cash() :: pos_integer()
  def initial_cash, do: @initial_cash

  @spec initial_reputation() :: pos_integer()
  def initial_reputation, do: @initial_reputation

  @spec stock_names() :: [String.t()]
  def stock_names, do: Map.keys(@stocks) |> Enum.sort()

  @spec init_players([String.t()]) :: %{String.t() => map()}
  def init_players(player_ids) do
    names =
      @player_names
      |> Enum.shuffle()
      |> Enum.take(length(player_ids))

    long_book = Enum.into(stock_names(), %{}, &{&1, 0})
    short_book = Enum.into(stock_names(), %{}, &{&1, 0})

    player_ids
    |> Enum.zip(names)
    |> Enum.into(%{}, fn {id, name} ->
      {id,
       %{
         cash: @initial_cash,
         portfolio: long_book,
         short_book: short_book,
         tips_received: [],
         trade_history: [],
         reputation: @initial_reputation,
         reputation_history: [@initial_reputation],
         name: name
       }}
    end)
  end

  @spec init_stocks() :: map()
  def init_stocks do
    Enum.into(@stocks, %{}, fn {ticker, config} ->
      {ticker,
       %{
         price: config.initial_price,
         volatility: config.volatility,
         history: [config.initial_price]
       }}
    end)
  end

  @spec generate_target_prices() :: %{pos_integer() => %{String.t() => number()}}
  def generate_target_prices do
    Enum.reduce(1..@max_rounds, %{}, fn round, acc ->
      targets =
        Enum.into(@stocks, %{}, fn {ticker, config} ->
          prev_target =
            if round == 1 do
              config.initial_price
            else
              get_in(acc, [round - 1, ticker]) || config.initial_price
            end

          momentum = if round > 1 and :rand.uniform() > 0.6, do: :rand.uniform() * 8 - 4, else: 0
          delta = (:rand.uniform() * 30 - 15 + momentum) * config.volatility
          new_target = max(5.0, prev_target + delta)
          {ticker, Float.round(new_target, 2)}
        end)

      Map.put(acc, round, targets)
    end)
  end

  @spec generate_market_news(pos_integer(), map(), map()) :: String.t()
  def generate_market_news(round, stocks, target_prices) do
    round_targets = Map.get(target_prices, round, %{})
    {regime, macro_line} = Enum.at(@macro_regimes, rem(round - 1, length(@macro_regimes)))

    movers =
      stock_names()
      |> Enum.map(fn ticker ->
        current = get_stock_price(stocks, ticker)
        target = Map.get(round_targets, ticker, current)
        diff = Float.round(target - current, 2)
        {ticker, diff}
      end)
      |> Enum.sort_by(fn {_ticker, diff} -> abs(diff) end, :desc)
      |> Enum.take(2)
      |> Enum.map(fn {ticker, diff} ->
        direction = if diff >= 0, do: "upside", else: "downside"
        "#{ticker} has the sharpest #{direction} skew"
      end)

    "Round #{round} Market Report: #{String.capitalize(regime)} regime, #{macro_line}. #{Enum.join(movers, ". ")}."
  end

  @spec distribute_tips([String.t()], pos_integer(), map(), map()) :: map()
  def distribute_tips(player_ids, round, target_prices, stocks) do
    round_targets = Map.get(target_prices, round, %{})
    recipient_count = max(2, min(length(player_ids), if(length(player_ids) <= 4, do: 2, else: 3)))
    recipients = Enum.take_random(player_ids, recipient_count)

    Enum.into(recipients, %{}, fn player_id ->
      tip_count = if(:rand.uniform() > 0.55, do: 2, else: 1)
      chosen_stocks = Enum.take_random(stock_names(), tip_count)

      tips =
        Enum.map(chosen_stocks, fn stock ->
          target = Map.get(round_targets, stock, 30.0)
          current_price = get_stock_price(stocks, stock)
          noise = target * (0.08 + :rand.uniform() * 0.12)
          low = max(5.0, target - noise) |> Float.round(0) |> trunc()
          high = (target + noise) |> Float.round(0) |> trunc()

          bias =
            cond do
              target >= current_price + 3 -> "bullish"
              target <= current_price - 3 -> "bearish"
              true -> "neutral"
            end

          catalyst = catalyst_hint(stock, bias)
          conviction = conviction_label(abs(target - current_price))

          %{
            round: round,
            stock: stock,
            hint_text:
              "#{stock} screens #{bias} with #{conviction} conviction. Desk color: #{catalyst}. Working range $#{low}-$#{high}.",
            price_range: %{low: low, high: high},
            bias: bias,
            catalyst: catalyst,
            conviction: conviction
          }
        end)

      {player_id, tips}
    end)
  end

  @spec resolve_prices(map(), map(), pos_integer(), map(), list()) :: map()
  def resolve_prices(stocks, trades, round, target_prices, market_calls \\ []) do
    round_targets = Map.get(target_prices, round, %{})

    trade_pressure =
      Enum.reduce(trades, Enum.into(stock_names(), %{}, &{&1, 0}), fn {_player_id, trade}, acc ->
        stock = get(trade, :stock)
        action = get(trade, :action)
        quantity = get(trade, :quantity) || 0

        case {action, stock} do
          {action_type, s} when action_type in ["buy", "cover"] and is_binary(s) ->
            Map.update(acc, s, quantity, &(&1 + quantity))

          {action_type, s} when action_type in ["sell", "short"] and is_binary(s) ->
            Map.update(acc, s, -quantity, &(&1 - quantity))

          _ ->
            acc
        end
      end)

    call_pressure = aggregate_market_calls(market_calls)

    Enum.into(stocks, %{}, fn {ticker, stock_data} ->
      current = get(stock_data, :price, 0)
      volatility = get(stock_data, :volatility, 1.0)
      history = get(stock_data, :history, [])
      target = Map.get(round_targets, ticker, current)
      net_trade_pressure = Map.get(trade_pressure, ticker, 0)
      sentiment_pressure = Map.get(call_pressure, ticker, 0)

      mean_reversion = 0.45 * (target - current)
      order_flow = 0.22 * net_trade_pressure
      narrative_effect = 0.28 * sentiment_pressure
      noise = (:rand.uniform() * 6 - 3) * volatility

      new_price = current + mean_reversion + order_flow + narrative_effect + noise
      new_price = max(1.0, Float.round(new_price, 2))

      {ticker,
       %{
         price: new_price,
         volatility: volatility,
         history: history ++ [new_price]
       }}
    end)
  end

  @spec execute_trades(map(), map(), map(), pos_integer()) :: {map(), list()}
  def execute_trades(players, trades, stocks, round) do
    Enum.reduce(trades, {players, []}, fn {player_id, trade}, {acc_players, acc_log} ->
      player = Map.get(acc_players, player_id)

      if is_nil(player) do
        {acc_players, acc_log}
      else
        action = get(trade, :action, "hold")
        stock = get(trade, :stock)
        quantity = get(trade, :quantity, 0)
        price = get_stock_price(stocks, stock)

        case action do
          "buy" ->
            maybe_execute_buy(
              acc_players,
              acc_log,
              player_id,
              player,
              stock,
              quantity,
              price,
              round
            )

          "sell" ->
            maybe_execute_sell(
              acc_players,
              acc_log,
              player_id,
              player,
              stock,
              quantity,
              price,
              round
            )

          "short" ->
            maybe_execute_short(
              acc_players,
              acc_log,
              player_id,
              player,
              stock,
              quantity,
              price,
              round,
              stocks
            )

          "cover" ->
            maybe_execute_cover(
              acc_players,
              acc_log,
              player_id,
              player,
              stock,
              quantity,
              price,
              round
            )

          "hold" ->
            entry = %{player: player_id, action: "hold", stock: nil, quantity: 0, price: 0}
            {acc_players, acc_log ++ [entry]}

          _ ->
            {acc_players, acc_log}
        end
      end
    end)
  end

  @spec update_reputations(map(), list(), map()) :: {map(), list()}
  def update_reputations(players, market_calls, price_changes) do
    Enum.reduce(market_calls, {players, []}, fn call, {acc_players, acc_updates} ->
      player_id = get(call, :player)
      stock = get(call, :stock)
      stance = get(call, :stance)
      confidence = get(call, :confidence, 1)
      change = price_changes |> Map.get(stock, %{}) |> get(:change, 0)

      accurate? =
        case stance do
          "bullish" -> change > 0
          "bearish" -> change < 0
          _ -> false
        end

      impact = max(1, round(abs(change) + confidence))
      reputation_delta = if accurate?, do: impact, else: -impact

      updated_players =
        update_in(acc_players, [player_id], fn player ->
          if player do
            next_reputation =
              player
              |> get(:reputation, @initial_reputation)
              |> Kernel.+(reputation_delta)
              |> clamp(10, 100)

            history = get(player, :reputation_history, [@initial_reputation])

            player
            |> Map.put(:reputation, next_reputation)
            |> Map.put(:reputation_history, history ++ [next_reputation])
          else
            player
          end
        end)

      update_entry = %{
        player: player_id,
        stock: stock,
        accurate: accurate?,
        delta: reputation_delta,
        reputation:
          updated_players |> Map.get(player_id, %{}) |> get(:reputation, @initial_reputation)
      }

      {updated_players, acc_updates ++ [update_entry]}
    end)
  end

  @spec portfolio_value(map(), map()) :: number()
  def portfolio_value(player, stocks) do
    cash = get(player, :cash, 0)
    portfolio = get(player, :portfolio, %{})
    short_book = get(player, :short_book, %{})

    long_value =
      Enum.reduce(portfolio, 0, fn {ticker, shares}, acc ->
        acc + shares * get_stock_price(stocks, ticker)
      end)

    short_liability =
      Enum.reduce(short_book, 0, fn {ticker, shares}, acc ->
        acc + shares * get_stock_price(stocks, ticker)
      end)

    Float.round((cash + long_value - short_liability) * 1.0, 2)
  end

  @spec calculate_standings(map(), map()) :: {map(), list()}
  def calculate_standings(players, stocks) do
    values =
      Enum.into(players, %{}, fn {id, player} ->
        {id, portfolio_value(player, stocks)}
      end)

    standings =
      values
      |> Enum.sort_by(fn {_id, val} -> val end, :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {{id, val}, rank} ->
        %{rank: rank, player: id, total_value: val}
      end)

    {values, standings}
  end

  @spec max_short_capacity(map(), map(), String.t()) :: non_neg_integer()
  def max_short_capacity(player, stocks, ticker) do
    equity = portfolio_value(player, stocks)
    current_short = get(player, :short_book, %{}) |> Map.get(ticker, 0)
    current_exposure = total_short_exposure(player, stocks)
    remaining_notional = max(0.0, equity * @short_exposure_ratio - current_exposure)

    additional =
      if get_stock_price(stocks, ticker) > 0,
        do: floor(remaining_notional / get_stock_price(stocks, ticker)),
        else: 0

    max(0, current_short + additional)
  end

  @spec turn_order([String.t()] | map(), pos_integer()) :: [String.t()]
  def turn_order(players_or_ids, round_number \\ 1)

  def turn_order(player_ids, round_number) when is_list(player_ids) do
    player_ids
    |> Enum.sort()
    |> rotate(max(0, round_number - 1))
  end

  def turn_order(players, round_number) when is_map(players) do
    players
    |> Map.keys()
    |> turn_order(round_number)
  end

  @spec sentiment_signal(String.t(), String.t()) :: integer()
  def sentiment_signal(statement, ticker) when is_binary(statement) and is_binary(ticker) do
    normalized = String.downcase(statement)

    if String.contains?(normalized, String.downcase(ticker)) do
      bullish = Enum.count(@bullish_words, &String.contains?(normalized, &1))
      bearish = Enum.count(@bearish_words, &String.contains?(normalized, &1))
      bullish - bearish
    else
      0
    end
  end

  def sentiment_signal(_, _), do: 0

  @spec get_stock_price(map(), String.t()) :: number()
  def get_stock_price(stocks, ticker) do
    stock = Map.get(stocks, ticker, %{})
    get(stock, :price, 0)
  end

  defp maybe_execute_buy(acc_players, acc_log, player_id, player, stock, quantity, price, round) do
    cost = price * quantity
    cash = get(player, :cash, 0)

    if cost <= cash and quantity > 0 do
      portfolio = get(player, :portfolio, %{})
      current_shares = Map.get(portfolio, stock, 0)
      new_portfolio = Map.put(portfolio, stock, current_shares + quantity)
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash - cost)
        |> Map.put(:portfolio, new_portfolio)
        |> Map.put(
          :trade_history,
          trade_history ++
            [%{round: round, action: "buy", stock: stock, quantity: quantity, price: price}]
        )

      entry = %{player: player_id, action: "buy", stock: stock, quantity: quantity, price: price}
      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "buy_rejected",
        stock,
        quantity,
        "insufficient funds"
      )
    end
  end

  defp maybe_execute_sell(acc_players, acc_log, player_id, player, stock, quantity, price, round) do
    portfolio = get(player, :portfolio, %{})
    current_shares = Map.get(portfolio, stock, 0)

    if quantity > 0 and quantity <= current_shares do
      cash = get(player, :cash, 0)
      proceeds = price * quantity
      new_portfolio = Map.put(portfolio, stock, current_shares - quantity)
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash + proceeds)
        |> Map.put(:portfolio, new_portfolio)
        |> Map.put(
          :trade_history,
          trade_history ++
            [%{round: round, action: "sell", stock: stock, quantity: quantity, price: price}]
        )

      entry = %{player: player_id, action: "sell", stock: stock, quantity: quantity, price: price}
      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "sell_rejected",
        stock,
        quantity,
        "insufficient shares"
      )
    end
  end

  defp maybe_execute_short(
         acc_players,
         acc_log,
         player_id,
         player,
         stock,
         quantity,
         price,
         round,
         stocks
       ) do
    max_short = max_short_capacity(player, stocks, stock)
    current_short = get(player, :short_book, %{}) |> Map.get(stock, 0)

    if quantity > 0 and current_short + quantity <= max_short do
      cash = get(player, :cash, 0)
      short_book = get(player, :short_book, %{})
      proceeds = price * quantity
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash + proceeds)
        |> Map.put(:short_book, Map.put(short_book, stock, current_short + quantity))
        |> Map.put(
          :trade_history,
          trade_history ++
            [%{round: round, action: "short", stock: stock, quantity: quantity, price: price}]
        )

      entry = %{
        player: player_id,
        action: "short",
        stock: stock,
        quantity: quantity,
        price: price
      }

      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "short_rejected",
        stock,
        quantity,
        "short capacity exceeded"
      )
    end
  end

  defp maybe_execute_cover(acc_players, acc_log, player_id, player, stock, quantity, price, round) do
    short_book = get(player, :short_book, %{})
    current_short = Map.get(short_book, stock, 0)
    cash = get(player, :cash, 0)
    cost = price * quantity

    if quantity > 0 and quantity <= current_short and cost <= cash do
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash - cost)
        |> Map.put(:short_book, Map.put(short_book, stock, current_short - quantity))
        |> Map.put(
          :trade_history,
          trade_history ++
            [%{round: round, action: "cover", stock: stock, quantity: quantity, price: price}]
        )

      entry = %{
        player: player_id,
        action: "cover",
        stock: stock,
        quantity: quantity,
        price: price
      }

      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "cover_rejected",
        stock,
        quantity,
        "cannot cover that position"
      )
    end
  end

  defp reject_trade(acc_players, acc_log, player_id, action, stock, quantity, reason) do
    {
      acc_players,
      acc_log ++
        [%{player: player_id, action: action, stock: stock, quantity: quantity, reason: reason}]
    }
  end

  defp aggregate_market_calls(market_calls) do
    Enum.reduce(market_calls, %{}, fn call, acc ->
      stock = get(call, :stock)
      stance = get(call, :stance)
      confidence = max(get(call, :confidence, 1), 1)
      reputation = get(call, :reputation, @initial_reputation)
      weight = confidence * (0.5 + reputation / 50)

      effect =
        case stance do
          "bullish" -> weight
          "bearish" -> -weight
          _ -> 0
        end

      if is_binary(stock) do
        Map.update(acc, stock, effect, &(&1 + effect))
      else
        acc
      end
    end)
  end

  defp total_short_exposure(player, stocks) do
    player
    |> get(:short_book, %{})
    |> Enum.reduce(0.0, fn {ticker, shares}, acc ->
      acc + shares * get_stock_price(stocks, ticker)
    end)
  end

  defp catalyst_hint(stock, bias) do
    base =
      case stock do
        "NOVA" -> "channel checks on AI server demand"
        "PULSE" -> "trial-readout chatter and regulatory rumors"
        "SAFE" -> "macro desks debating the next rate move"
        "TERRA" -> "supply shock talk and inventory whispers"
        "VISTA" -> "consumer spend data and ad-demand checks"
        _ -> "cross-asset desk chatter"
      end

    if bias == "neutral", do: "#{base} look mixed", else: base
  end

  defp conviction_label(diff) when diff >= 12, do: "high"
  defp conviction_label(diff) when diff >= 6, do: "medium"
  defp conviction_label(_diff), do: "low"

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp rotate([], _offset), do: []

  defp rotate(list, offset) do
    normalized = rem(offset, length(list))
    {head, tail} = Enum.split(list, normalized)
    tail ++ head
  end
end
