defmodule LemonSim.Examples.StockMarket.Market do
  @moduledoc """
  Market mechanics, player management, and price generation for Stock Market Arena.
  """

  import LemonSim.GameHelpers

  @stocks %{
    "NOVA" => %{
      initial_price: 50,
      volatility: 0.8,
      label: "AI infrastructure",
      sector: "technology"
    },
    "PULSE" => %{
      initial_price: 36,
      volatility: 1.0,
      label: "biotech moonshot",
      sector: "healthcare"
    },
    "SAFE" => %{initial_price: 20, volatility: 0.2, label: "government bonds", sector: "rates"},
    "TERRA" => %{
      initial_price: 30,
      volatility: 0.5,
      label: "commodities complex",
      sector: "materials"
    },
    "VISTA" => %{
      initial_price: 42,
      volatility: 0.6,
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

  @trader_names [
    "Morgan",
    "Quinn",
    "Reeves",
    "Sterling",
    "Blake",
    "Hartley",
    "Cross",
    "Vale",
    "Pierce",
    "Sloan",
    "Barrett",
    "Lennox",
    "Drake",
    "Ellis",
    "Griffin",
    "Hayes"
  ]

  @traits ~w(bull_headed contrarian insider risk_junkie conservative analyst bluffer patient)

  @trait_descriptions %{
    "bull_headed" =>
      "You are BULL-HEADED — you pick a thesis and ride it hard. Once you're in, you double down. Conviction is your edge.",
    "contrarian" =>
      "You are a CONTRARIAN — when everyone zigs, you zag. Consensus trades disgust you. The crowd is always wrong.",
    "insider" =>
      "You are an INSIDER — you trade on information edge. You hoard tips, cultivate sources, and never share your real thesis.",
    "risk_junkie" =>
      "You are a RISK JUNKIE — big positions, high leverage, maximum exposure. Small gains bore you. You want the ten-bagger.",
    "conservative" =>
      "You are CONSERVATIVE — capital preservation first. You size positions carefully, hedge constantly, and sleep well at night.",
    "analyst" =>
      "You are an ANALYST — you crunch numbers, track patterns, and trust fundamentals over narratives. Data doesn't lie.",
    "bluffer" =>
      "You are a BLUFFER — your public calls are weapons, not predictions. You talk your book, mislead competitors, and profit from confusion.",
    "patient" =>
      "You are PATIENT — you wait for asymmetric setups and ignore noise. Most rounds you do nothing interesting. When you strike, you strike big."
  }

  @connection_types ~w(former_partners fund_rivals classmates mentor_protege old_grudge drinking_buddies)

  @connection_templates %{
    "former_partners" =>
      " used to run a fund together before a messy split. They know each other's strategies inside out.",
    "fund_rivals" =>
      " have been competing for the same institutional capital for years. Every quarter is a grudge match.",
    "classmates" =>
      " went through the same MBA program. They formed their trading philosophies in the same classroom.",
    "mentor_protege" =>
      ": the first taught the second everything about markets. Now the student may have surpassed the teacher.",
    "old_grudge" =>
      " haven't spoken since one cost the other a fortune on a bad trade recommendation.",
    "drinking_buddies" =>
      " are regulars at the same bar after market close. They share too much after a few drinks."
  }
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

  # --- Market microstructure ---
  @max_order_shares 500
  @max_long_position 2000
  @slippage_coeff 0.03
  @slippage_liquidity 8_000.0
  @commission_rate 0.025
  @short_borrow_rate 0.05
  @circuit_breaker_pct 0.15
  @price_floor 0.50
  @flow_base 5_000.0
  @max_flow 10.0

  @spec stock_config() :: map()
  def stock_config, do: @stocks

  @spec initial_cash() :: pos_integer()
  def initial_cash, do: @initial_cash

  @spec initial_reputation() :: pos_integer()
  def initial_reputation, do: @initial_reputation

  @spec trader_names(pos_integer()) :: [String.t()]
  def trader_names(count) do
    @trader_names
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @spec assign_traits([String.t()]) :: %{String.t() => [String.t()]}
  def assign_traits(names) do
    Enum.into(names, %{}, fn name ->
      primary = Enum.random(@traits)
      secondary = @traits |> List.delete(primary) |> Enum.random()
      {name, [primary, secondary]}
    end)
  end

  @spec trait_description(String.t()) :: String.t() | nil
  def trait_description(trait) do
    Map.get(@trait_descriptions, trait)
  end

  @spec generate_connections([String.t()]) :: [map()]
  def generate_connections(names) when length(names) < 2, do: []

  def generate_connections(names) do
    pairs = for a <- names, b <- names, a < b, do: {a, b}
    count = min(length(pairs), max(1, div(length(names), 2)))

    pairs
    |> Enum.shuffle()
    |> Enum.take(count)
    |> Enum.map(fn {a, b} ->
      type = Enum.random(@connection_types)
      template = Map.get(@connection_templates, type, "")
      description = "#{a} and #{b}" <> template

      %{
        players: [a, b],
        type: type,
        description: description
      }
    end)
  end

  @spec connections_for_player([map()], String.t()) :: [map()]
  def connections_for_player(connections, player_id) do
    Enum.filter(connections, fn conn ->
      player_id in Map.get(conn, :players, [])
    end)
  end

  @spec stock_names() :: [String.t()]
  def stock_names, do: Map.keys(@stocks) |> Enum.sort()

  @spec max_order_shares() :: pos_integer()
  def max_order_shares, do: @max_order_shares

  @spec slippage_impact(non_neg_integer(), number()) :: float()
  def slippage_impact(quantity, price) when quantity > 0 and price > 0 do
    notional = quantity * price * 1.0
    @slippage_coeff * :math.sqrt(notional / @slippage_liquidity)
  end

  def slippage_impact(_quantity, _price), do: 0.0

  @spec max_buy_quantity(map(), map(), String.t()) :: non_neg_integer()
  def max_buy_quantity(player, stocks, ticker) do
    cash = get(player, :cash, 0)
    price = get_stock_price(stocks, ticker)
    current_held = get(player, :portfolio, %{}) |> Map.get(ticker, 0)
    position_room = max(0, @max_long_position - current_held)

    if price <= 0 do
      0
    else
      naive_max = floor(cash / price)
      upper = min(naive_max, min(@max_order_shares, position_room))
      find_max_affordable(cash, price, 0, upper)
    end
  end

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

          # Pull target back toward initial price — prevents secular drift
          anchor_pull = 0.20 * (config.initial_price - prev_target)
          momentum = if round > 1 and :rand.uniform() > 0.6, do: :rand.uniform() * 6 - 3, else: 0
          delta = (:rand.uniform() * 16 - 8 + momentum + anchor_pull) * config.volatility
          new_target = max(5.0, prev_target + delta)
          {ticker, Float.round(new_target, 2)}
        end)

      Map.put(acc, round, targets)
    end)
  end

  @spec generate_market_news(pos_integer(), map(), map()) :: String.t()
  def generate_market_news(round, stocks, _target_prices) do
    {regime, macro_line} = Enum.at(@macro_regimes, rem(round - 1, length(@macro_regimes)))

    # Mention the most volatile stocks (by recent move), without revealing direction
    movers =
      stock_names()
      |> Enum.map(fn ticker ->
        stock_data = Map.get(stocks, ticker, %{})
        history = get(stock_data, :history, [])
        current = get(stock_data, :price, 0)

        prev =
          case history do
            [] -> current
            h -> List.last(h, current)
          end

        move_pct = if prev > 0, do: abs(current - prev) / prev * 100, else: 0
        {ticker, move_pct}
      end)
      |> Enum.sort_by(fn {_ticker, pct} -> pct end, :desc)
      |> Enum.take(2)
      |> Enum.map(fn {ticker, _pct} ->
        stock_config = Map.get(@stocks, ticker, %{})
        "#{ticker} (#{stock_config[:label]}) is seeing elevated activity"
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

    # Dollar-weighted trade pressure (not raw shares)
    dollar_pressure =
      Enum.reduce(trades, Enum.into(stock_names(), %{}, &{&1, 0.0}), fn {_player_id, trade},
                                                                        acc ->
        stock = get(trade, :stock)
        action = get(trade, :action)
        quantity = (get(trade, :quantity) || 0) * 1.0
        price = get_stock_price(stocks, stock) * 1.0

        case {action, stock} do
          {action_type, s} when action_type in ["buy", "cover"] and is_binary(s) ->
            Map.update(acc, s, quantity * price, &(&1 + quantity * price))

          {action_type, s} when action_type in ["sell", "short"] and is_binary(s) ->
            Map.update(acc, s, -(quantity * price), &(&1 - quantity * price))

          _ ->
            acc
        end
      end)

    call_pressure = aggregate_market_calls(market_calls)

    Enum.into(stocks, %{}, fn {ticker, stock_data} ->
      current = get(stock_data, :price, 0) * 1.0
      volatility = get(stock_data, :volatility, 1.0)
      history = get(stock_data, :history, [])
      target = Map.get(round_targets, ticker, current)

      # Log-scaled dollar flow (diminishing returns for large trades)
      raw_dollar_flow = Map.get(dollar_pressure, ticker, 0.0)
      log_flow = signed_log_flow(raw_dollar_flow)
      capped_flow = clamp(log_flow, -@max_flow, @max_flow)

      sentiment_pressure = Map.get(call_pressure, ticker, 0)
      initial_price = (@stocks[ticker] || %{})[:initial_price] || current

      mean_reversion = 0.12 * (target - current)
      # Pull price back toward initial — prevents runaway trends
      anchor_reversion = 0.05 * (initial_price - current)
      order_flow = 0.30 * capped_flow
      narrative_effect = 0.28 * sentiment_pressure
      noise = (:rand.uniform() * 14 - 7) * volatility

      new_price =
        current + mean_reversion + anchor_reversion + order_flow + narrative_effect + noise

      # Circuit breaker: cap move to ±60% per round
      new_price =
        clamp(
          new_price,
          current * (1 - @circuit_breaker_pct),
          current * (1 + @circuit_breaker_pct)
        )

      new_price = max(@price_floor, Float.round(new_price, 2))

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

  @spec apply_short_borrow_costs(map(), map()) :: map()
  def apply_short_borrow_costs(players, stocks) do
    Enum.into(players, %{}, fn {id, player} ->
      short_book = get(player, :short_book, %{})

      borrow_cost =
        Enum.reduce(short_book, 0.0, fn {ticker, shares}, acc ->
          acc + shares * get_stock_price(stocks, ticker) * @short_borrow_rate
        end)

      cash = get(player, :cash, 0)
      {id, Map.put(player, :cash, cash - borrow_cost)}
    end)
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
        do: min(floor(remaining_notional / get_stock_price(stocks, ticker)), @max_order_shares),
        else: 0

    max(0, current_short + max(0, additional))
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
    cash = get(player, :cash, 0)
    portfolio = get(player, :portfolio, %{})
    current_shares = Map.get(portfolio, stock, 0)
    position_room = max(0, @max_long_position - current_shares)

    # Clamp to order size and position limits
    quantity = quantity |> min(@max_order_shares) |> min(position_room)

    impact = slippage_impact(quantity, price)
    eff_price = price * (1 + impact)
    notional = eff_price * quantity
    commission = notional * @commission_rate
    total_cost = notional + commission

    if total_cost <= cash and quantity > 0 do
      new_portfolio = Map.put(portfolio, stock, current_shares + quantity)
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash - total_cost)
        |> Map.put(:portfolio, new_portfolio)
        |> Map.put(
          :trade_history,
          trade_history ++
            [
              %{
                round: round,
                action: "buy",
                stock: stock,
                quantity: quantity,
                price: Float.round(eff_price * 1.0, 2)
              }
            ]
        )

      entry = %{
        player: player_id,
        action: "buy",
        stock: stock,
        quantity: quantity,
        price: Float.round(eff_price * 1.0, 2)
      }

      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reason = if quantity <= 0, do: "position limit reached", else: "insufficient funds"

      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "buy_rejected",
        stock,
        quantity,
        reason
      )
    end
  end

  defp maybe_execute_sell(acc_players, acc_log, player_id, player, stock, quantity, price, round) do
    portfolio = get(player, :portfolio, %{})
    current_shares = Map.get(portfolio, stock, 0)

    # Clamp to order size and available shares
    quantity = quantity |> min(@max_order_shares) |> min(current_shares)

    if quantity > 0 do
      cash = get(player, :cash, 0)
      impact = slippage_impact(quantity, price)
      eff_price = max(0.01, price * (1 - impact))
      notional = eff_price * quantity
      commission = notional * @commission_rate
      net_proceeds = notional - commission
      new_portfolio = Map.put(portfolio, stock, current_shares - quantity)
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash + net_proceeds)
        |> Map.put(:portfolio, new_portfolio)
        |> Map.put(
          :trade_history,
          trade_history ++
            [
              %{
                round: round,
                action: "sell",
                stock: stock,
                quantity: quantity,
                price: Float.round(eff_price * 1.0, 2)
              }
            ]
        )

      entry = %{
        player: player_id,
        action: "sell",
        stock: stock,
        quantity: quantity,
        price: Float.round(eff_price * 1.0, 2)
      }

      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "sell_rejected",
        stock,
        quantity,
        "no shares to sell"
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
    available = max(0, max_short - current_short)

    # Clamp to order size and available short capacity
    quantity = quantity |> min(@max_order_shares) |> min(available)

    if quantity > 0 do
      cash = get(player, :cash, 0)
      short_book = get(player, :short_book, %{})
      impact = slippage_impact(quantity, price)
      eff_price = max(0.01, price * (1 - impact))
      notional = eff_price * quantity
      commission = notional * @commission_rate
      net_proceeds = notional - commission
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash + net_proceeds)
        |> Map.put(:short_book, Map.put(short_book, stock, current_short + quantity))
        |> Map.put(
          :trade_history,
          trade_history ++
            [
              %{
                round: round,
                action: "short",
                stock: stock,
                quantity: quantity,
                price: Float.round(eff_price * 1.0, 2)
              }
            ]
        )

      entry = %{
        player: player_id,
        action: "short",
        stock: stock,
        quantity: quantity,
        price: Float.round(eff_price * 1.0, 2)
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

    # Clamp to order size and current short position
    quantity = quantity |> min(@max_order_shares) |> min(current_short)

    impact = slippage_impact(quantity, price)
    eff_price = price * (1 + impact)
    notional = eff_price * quantity
    commission = notional * @commission_rate
    total_cost = notional + commission

    if quantity > 0 and total_cost <= cash do
      trade_history = get(player, :trade_history, [])

      updated_player =
        player
        |> Map.put(:cash, cash - total_cost)
        |> Map.put(:short_book, Map.put(short_book, stock, current_short - quantity))
        |> Map.put(
          :trade_history,
          trade_history ++
            [
              %{
                round: round,
                action: "cover",
                stock: stock,
                quantity: quantity,
                price: Float.round(eff_price * 1.0, 2)
              }
            ]
        )

      entry = %{
        player: player_id,
        action: "cover",
        stock: stock,
        quantity: quantity,
        price: Float.round(eff_price * 1.0, 2)
      }

      {Map.put(acc_players, player_id, updated_player), acc_log ++ [entry]}
    else
      reason = if quantity <= 0, do: "no short position to cover", else: "insufficient funds"

      reject_trade(
        acc_players,
        acc_log,
        player_id,
        "cover_rejected",
        stock,
        quantity,
        reason
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

  defp signed_log_flow(dollar_flow) when dollar_flow >= 0 do
    :math.log2(1 + abs(dollar_flow) / @flow_base)
  end

  defp signed_log_flow(dollar_flow) do
    -:math.log2(1 + abs(dollar_flow) / @flow_base)
  end

  defp find_max_affordable(_cash, _price, lo, hi) when hi <= lo, do: lo

  defp find_max_affordable(cash, price, lo, hi) do
    mid = div(lo + hi + 1, 2)
    impact = slippage_impact(mid, price)
    notional = mid * price * (1 + impact)
    cost = notional * (1 + @commission_rate)

    if cost <= cash do
      find_max_affordable(cash, price, mid, hi)
    else
      find_max_affordable(cash, price, lo, mid - 1)
    end
  end

  defp rotate([], _offset), do: []

  defp rotate(list, offset) do
    normalized = rem(offset, length(list))
    {head, tail} = Enum.split(list, normalized)
    tail ++ head
  end
end
