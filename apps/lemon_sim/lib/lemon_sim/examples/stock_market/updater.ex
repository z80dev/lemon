defmodule LemonSim.Examples.StockMarket.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers

  alias LemonSim.State
  alias LemonSim.Examples.StockMarket.{Events, Market}

  @discussion_round_limit 2

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "make_statement" -> apply_make_statement(state, event)
      "broadcast_market_call" -> apply_broadcast_market_call(state, event)
      "send_whisper" -> apply_send_whisper(state, event)
      "skip_whisper" -> apply_skip_whisper(state, event)
      "place_trade" -> apply_place_trade(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  defp apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_discussion_round(state.world, 1),
         :ok <- ensure_active_actor(state.world, player_id) do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: player_id, statement: statement, type: "statement"}

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{discussion_transcript: transcript ++ [new_entry]})
        )
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_broadcast_market_call(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    stock = fetch(event.payload, :stock, "stock")
    stance = fetch(event.payload, :stance, "stance")
    confidence = fetch(event.payload, :confidence, "confidence") || 3
    thesis = fetch(event.payload, :thesis, "thesis")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_discussion_round(state.world, 1),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_market_call(stock, stance, confidence) do
      market_calls = get(state.world, :market_calls, [])
      transcript = get(state.world, :discussion_transcript, [])

      call = %{
        round: get(state.world, :round, 1),
        player: player_id,
        stock: stock,
        stance: stance,
        confidence: confidence,
        thesis: thesis,
        reputation: players_reputation(state.world, player_id)
      }

      transcript_entry = %{
        player: player_id,
        type: "market_call",
        statement: "#{stock} #{String.upcase(stance)} (#{confidence}/5): #{thesis}",
        stock: stock,
        stance: stance,
        confidence: confidence
      }

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            market_calls: market_calls ++ [call],
            discussion_transcript: transcript ++ [transcript_entry]
          })
        )
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_send_whisper(%State{} = state, event) do
    from_id =
      fetch(event.payload, :from_id, "from_id") ||
        fetch(event.payload, :player_id, "player_id")

    to_id = fetch(event.payload, :to_id, "to_id")
    message = fetch(event.payload, :message, "message")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_discussion_round(state.world, 2),
         :ok <- ensure_active_actor(state.world, from_id),
         :ok <- ensure_player_exists(players, to_id),
         :ok <- ensure_different(from_id, to_id) do
      whisper_log = get(state.world, :whisper_log, [])
      whisper_graph = get(state.world, :whisper_graph, [])
      whisper_history = get(state.world, :whisper_history, [])

      whisper = %{round: get(state.world, :round, 1), from: from_id, to: to_id, message: message}

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            whisper_log: whisper_log ++ [whisper],
            whisper_graph: whisper_graph ++ [%{from: from_id, to: to_id}],
            whisper_history: whisper_history ++ [whisper]
          })
        )
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, from_id, reason)
    end
  end

  defp apply_skip_whisper(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_discussion_round(state.world, 2),
         :ok <- ensure_active_actor(state.world, player_id) do
      next_state =
        state
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_place_trade(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    action = fetch(event.payload, :action, "action") || "hold"
    stock = fetch(event.payload, :stock, "stock")
    quantity = fetch(event.payload, :quantity, "quantity") || 0
    players = get(state.world, :players, %{})
    stocks = get(state.world, :stocks, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "trading"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- validate_trade(players, stocks, player_id, action, stock, quantity) do
      trades = get(state.world, :trades, %{})
      new_trade = %{action: action, stock: stock, quantity: quantity}

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{trades: Map.put(trades, player_id, new_trade)})
        )
        |> State.append_event(event)

      advance_trading_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id)
    round = get(state.world, :round, 1)
    discussion_round = get(state.world, :discussion_round, 1)
    players = get(state.world, :players, %{})

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        if discussion_round < get(state.world, :discussion_round_limit, @discussion_round_limit) do
          next_discussion_round = discussion_round + 1
          next_turn_order = Market.turn_order(players, round + next_discussion_round - 1)
          first_actor = List.first(next_turn_order)

          next_state =
            State.put_world(
              state,
              world_updates(state.world, %{
                discussion_round: next_discussion_round,
                turn_order: next_turn_order,
                active_actor_id: first_actor
              })
            )

          {:ok, next_state, {:decide, "#{first_actor} discussion turn"}}
        else
          transition_to_trading(state)
        end

      next_actor ->
        next_state =
          State.put_world(state, world_updates(state.world, %{active_actor_id: next_actor}))

        {:ok, next_state, {:decide, "#{next_actor} discussion turn"}}
    end
  end

  defp advance_trading_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        resolve_round(state)

      next_actor ->
        next_state =
          State.put_world(state, world_updates(state.world, %{active_actor_id: next_actor}))

        {:ok, next_state, {:decide, "#{next_actor} trading turn"}}
    end
  end

  defp transition_to_trading(%State{} = state) do
    players = get(state.world, :players, %{})
    round = get(state.world, :round, 1)
    trading_order = Market.turn_order(players, round + 1)
    first_trader = List.first(trading_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "trading",
          trades: %{},
          turn_order: trading_order,
          active_actor_id: first_trader
        })
      )
      |> State.append_event(Events.phase_changed("trading", round))

    {:ok, next_state, {:decide, "#{first_trader} trading turn"}}
  end

  defp resolve_round(%State{} = state) do
    round = get(state.world, :round, 1)
    max_rounds = get(state.world, :max_rounds, 10)
    trades = get(state.world, :trades, %{})
    stocks = get(state.world, :stocks, %{})
    players = get(state.world, :players, %{})
    target_prices = get(state.world, :target_prices, %{})
    market_calls = get(state.world, :market_calls, [])

    {post_trade_players, trade_log} = Market.execute_trades(players, trades, stocks, round)
    updated_stocks = Market.resolve_prices(stocks, trades, round, target_prices, market_calls)

    price_changes =
      Enum.into(Market.stock_names(), %{}, fn ticker ->
        old_price = Market.get_stock_price(stocks, ticker)
        new_price = Market.get_stock_price(updated_stocks, ticker)

        {ticker, %{old: old_price, new: new_price, change: Float.round(new_price - old_price, 2)}}
      end)

    {updated_players, reputation_updates} =
      Market.update_reputations(post_trade_players, market_calls, price_changes)

    {portfolio_values, standings} = Market.calculate_standings(updated_players, updated_stocks)

    round_summary =
      build_round_summary(
        round,
        updated_players,
        price_changes,
        portfolio_values,
        standings,
        trade_log,
        market_calls,
        reputation_updates
      )

    resolution_event = Events.round_resolved(round, price_changes, portfolio_values)
    round_summaries = get(state.world, :round_summaries, []) ++ [round_summary]
    market_call_history = get(state.world, :market_call_history, []) ++ market_calls

    if round >= max_rounds do
      winner = standings |> List.first() |> Map.get(:player)

      standings_text =
        Enum.map(standings, fn entry ->
          "#{entry.rank}. #{player_name(updated_players, entry.player)}: $#{Float.round(entry.total_value * 1.0, 2)}"
        end)
        |> Enum.join(", ")

      game_over_event =
        Events.game_over(
          winner,
          standings,
          "The bell rings. #{player_name(updated_players, winner)} wins the market with the top portfolio. Final standings: #{standings_text}"
        )

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            stocks: updated_stocks,
            trades: %{},
            market_calls: [],
            market_call_history: market_call_history,
            round_summaries: round_summaries,
            status: "game_over",
            winner: winner,
            phase: "game_over",
            active_actor_id: nil,
            turn_order: []
          })
        )
        |> State.append_events([
          resolution_event,
          Events.phase_changed("game_over", round),
          game_over_event
        ])

      {:ok, next_state, :skip}
    else
      start_next_round(
        state,
        updated_players,
        updated_stocks,
        round + 1,
        resolution_event,
        market_call_history,
        round_summaries
      )
    end
  end

  defp start_next_round(
         %State{} = state,
         players,
         stocks,
         next_round,
         preceding_event,
         market_call_history,
         round_summaries
       ) do
    target_prices = get(state.world, :target_prices, %{})
    player_ids = Map.keys(players) |> Enum.sort()
    news_text = Market.generate_market_news(next_round, stocks, target_prices)
    tips = Market.distribute_tips(player_ids, next_round, target_prices, stocks)

    updated_players =
      Enum.reduce(tips, players, fn {player_id, player_tips}, acc ->
        player = Map.get(acc, player_id)

        if player do
          existing_tips = get(player, :tips_received, [])
          updated = Map.put(player, :tips_received, existing_tips ++ player_tips)
          Map.put(acc, player_id, updated)
        else
          acc
        end
      end)

    tip_events =
      Enum.flat_map(tips, fn {player_id, player_tips} ->
        Enum.map(player_tips, fn tip ->
          Events.tip_received(player_id, tip.stock, tip.hint_text, tip.price_range)
        end)
      end)

    tips_summary =
      Enum.into(tips, %{}, fn {player_id, player_tips} ->
        {player_id, length(player_tips)}
      end)

    discussion_order = Market.turn_order(updated_players, next_round)
    first_speaker = List.first(discussion_order)
    news_event = Events.market_news_generated(next_round, news_text, tips_summary)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          players: updated_players,
          stocks: stocks,
          round: next_round,
          phase: "discussion",
          trades: %{},
          discussion_round: 1,
          discussion_round_limit: @discussion_round_limit,
          discussion_transcript: [],
          whisper_log: [],
          whisper_graph: [],
          market_calls: [],
          market_call_history: market_call_history,
          round_summaries: round_summaries,
          current_tips: tips,
          market_news: news_text,
          turn_order: discussion_order,
          active_actor_id: first_speaker
        })
      )
      |> State.append_events(
        [preceding_event, news_event] ++
          tip_events ++ [Events.phase_changed("discussion", next_round)]
      )

    {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
  end

  defp validate_trade(_players, _stocks, _player_id, "hold", _stock, _quantity), do: :ok

  defp validate_trade(players, stocks, player_id, "buy", stock, quantity) do
    player = Map.get(players, player_id, %{})
    cash = get(player, :cash, 0)
    price = Market.get_stock_price(stocks, stock)

    cond do
      stock not in Market.stock_names() -> {:error, :invalid_stock}
      quantity <= 0 -> {:error, :invalid_quantity}
      price * quantity > cash -> {:error, :insufficient_funds}
      true -> :ok
    end
  end

  defp validate_trade(players, _stocks, player_id, "sell", stock, quantity) do
    player = Map.get(players, player_id, %{})
    portfolio = get(player, :portfolio, %{})
    shares = Map.get(portfolio, stock, 0)

    cond do
      stock not in Market.stock_names() -> {:error, :invalid_stock}
      quantity <= 0 -> {:error, :invalid_quantity}
      quantity > shares -> {:error, :insufficient_shares}
      true -> :ok
    end
  end

  defp validate_trade(players, stocks, player_id, "short", stock, quantity) do
    player = Map.get(players, player_id, %{})
    max_short = Market.max_short_capacity(player, stocks, stock)
    current_short = get(player, :short_book, %{}) |> Map.get(stock, 0)

    cond do
      stock not in Market.stock_names() -> {:error, :invalid_stock}
      quantity <= 0 -> {:error, :invalid_quantity}
      current_short + quantity > max_short -> {:error, :short_capacity_exceeded}
      true -> :ok
    end
  end

  defp validate_trade(players, stocks, player_id, "cover", stock, quantity) do
    player = Map.get(players, player_id, %{})
    current_short = get(player, :short_book, %{}) |> Map.get(stock, 0)
    cash = get(player, :cash, 0)
    cost = Market.get_stock_price(stocks, stock) * quantity

    cond do
      stock not in Market.stock_names() -> {:error, :invalid_stock}
      quantity <= 0 -> {:error, :invalid_quantity}
      quantity > current_short -> {:error, :insufficient_short_position}
      cost > cash -> {:error, :insufficient_funds}
      true -> :ok
    end
  end

  defp validate_trade(_players, _stocks, _player_id, _action, _stock, _quantity) do
    {:error, :invalid_action}
  end

  defp ensure_player_exists(players, player_id) do
    if Map.has_key?(players, player_id), do: :ok, else: {:error, :unknown_player}
  end

  defp ensure_discussion_round(world, expected_round) do
    if get(world, :discussion_round, 1) == expected_round do
      :ok
    else
      {:error, :wrong_discussion_round}
    end
  end

  defp ensure_valid_market_call(stock, stance, confidence) do
    cond do
      stock not in Market.stock_names() -> {:error, :invalid_stock}
      stance not in ["bullish", "bearish"] -> {:error, :invalid_stance}
      not is_integer(confidence) -> {:error, :invalid_confidence}
      confidence < 1 or confidence > 5 -> {:error, :invalid_confidence}
      true -> :ok
    end
  end

  defp build_round_summary(
         round,
         players,
         price_changes,
         portfolio_values,
         standings,
         trade_log,
         market_calls,
         reputation_updates
       ) do
    biggest_move =
      price_changes
      |> Enum.max_by(fn {_ticker, data} -> abs(get(data, :change, 0)) end, fn ->
        {nil, %{change: 0}}
      end)
      |> case do
        {ticker, data} when is_binary(ticker) ->
          %{stock: ticker, change: get(data, :change, 0), new_price: get(data, :new)}

        _ ->
          nil
      end

    leader =
      standings
      |> List.first()
      |> case do
        nil ->
          nil

        entry ->
          %{
            player_id: entry.player,
            player_name: player_name(players, entry.player),
            total_value: entry.total_value
          }
      end

    %{
      round: round,
      leader: leader,
      biggest_move: biggest_move,
      portfolio_values: portfolio_values,
      price_changes: price_changes,
      trade_count:
        Enum.count(trade_log, fn trade ->
          get(trade, :action) in ["buy", "sell", "short", "cover"]
        end),
      market_call_count: length(market_calls),
      reputation_updates: reputation_updates,
      accurate_calls: Enum.count(reputation_updates, &get(&1, :accurate))
    }
  end

  defp players_reputation(world, player_id) do
    world
    |> get(:players, %{})
    |> Map.get(player_id, %{})
    |> get(:reputation, Market.initial_reputation())
  end

  defp player_name(players, player_id) do
    players
    |> Map.get(player_id, %{})
    |> get(:name, player_id)
  end
end
