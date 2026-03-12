defmodule LemonSim.Examples.StockMarket do
  @moduledoc """
  Stock Market trading game built on LemonSim.

  A multiplayer trading game where players compete over 10 rounds by combining
  public market signaling, private tips, whispers, and portfolio management.
  Public calls now influence prices directly, which makes persuasion and timing
  part of the benchmark rather than pure flavor text.
  """

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.EventHelpers

  alias LemonSim.GameHelpers.Runner, as: GameRunner
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.StockMarket.{
    ActionSpace,
    Events,
    Market,
    Performance,
    Updater
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.State

  @default_max_turns 500
  @default_player_count 4

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    player_ids = Enum.map(1..player_count, fn i -> "player_#{i}" end)
    players = Market.init_players(player_ids)
    stocks = Market.init_stocks()
    target_prices = Market.generate_target_prices()
    news_text = Market.generate_market_news(1, stocks, target_prices)
    tips = Market.distribute_tips(player_ids, 1, target_prices, stocks)

    players_with_tips =
      Enum.reduce(tips, players, fn {player_id, player_tips}, acc ->
        player = Map.get(acc, player_id)

        if player do
          Map.put(acc, player_id, Map.put(player, :tips_received, player_tips))
        else
          acc
        end
      end)

    discussion_order = Market.turn_order(players_with_tips, 1)
    first_speaker = List.first(discussion_order)

    %{
      players: players_with_tips,
      stocks: stocks,
      target_prices: target_prices,
      phase: "discussion",
      round: 1,
      max_rounds: 10,
      discussion_round: 1,
      discussion_round_limit: 2,
      active_actor_id: first_speaker,
      turn_order: discussion_order,
      current_tips: tips,
      discussion_transcript: [],
      whisper_log: [],
      whisper_graph: [],
      whisper_history: [],
      market_calls: [],
      market_call_history: [],
      round_summaries: [],
      trades: %{},
      market_news: news_text,
      status: "in_progress",
      winner: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "stock_market_#{:erlang.phash2(:erlang.monotonic_time())}")

    world = initial_world(opts)

    tips_summary =
      world
      |> get(:current_tips, %{})
      |> Enum.into(%{}, fn {player_id, player_tips} -> {player_id, length(player_tips)} end)

    news_event = Events.market_news_generated(1, get(world, :market_news, ""), tips_summary)

    tip_events =
      world
      |> get(:current_tips, %{})
      |> Enum.flat_map(fn {player_id, player_tips} ->
        Enum.map(player_tips, fn tip ->
          Events.tip_received(player_id, tip.stock, tip.hint_text, tip.price_range)
        end)
      end)

    phase_event = Events.phase_changed("discussion", 1)

    state =
      State.new(
        sim_id: sim_id,
        world: world,
        intent: %{
          goal:
            "Compete in a watchable, information-heavy stock market game. " <>
              "Use public calls to move sentiment, private tips to gain edge, whispers to coordinate or mislead, " <>
              "and disciplined trades to finish with the highest portfolio value."
        },
        plan_history: []
      )

    state
    |> State.append_events([news_event] ++ tip_events ++ [phase_event])
  end

  @spec modules() :: map()
  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      section_builders: %{
        world_state: fn frame, _tools, _opts ->
          world = frame.world
          actor_id = get(world, :active_actor_id)

          %{
            id: :world_state,
            title: "Trading Floor",
            format: :json,
            content: build_market_view(world, actor_id)
          }
        end,
        role_info: fn frame, _tools, _opts ->
          world = frame.world
          actor_id = get(world, :active_actor_id)

          %{
            id: :role_info,
            title: "Your Book (SECRET - trade on it, reveal selectively)",
            format: :json,
            content: build_private_info(world, actor_id)
          }
        end,
        discussion_log: fn frame, _tools, _opts ->
          world = frame.world
          actor_id = get(world, :active_actor_id)
          players = get(world, :players, %{})
          transcript = get(world, :discussion_transcript, [])
          market_calls = get(world, :market_calls, [])
          whisper_graph = get(world, :whisper_graph, [])
          whisper_log = get(world, :whisper_log, [])

          visible_whispers =
            Enum.filter(whisper_log, fn entry ->
              get(entry, :from) == actor_id or get(entry, :to) == actor_id
            end)

          %{
            id: :discussion_log,
            title: "Signal Board",
            format: :json,
            content: %{
              "public_tape" =>
                Enum.map(transcript, fn entry ->
                  player_id = get(entry, :player)

                  %{
                    "player_id" => player_id,
                    "player_name" => player_name(players, player_id),
                    "type" => get(entry, :type, "statement"),
                    "statement" => rewrite_public_text(get(entry, :statement, ""), players)
                  }
                end),
              "public_market_calls" =>
                Enum.map(market_calls, fn call ->
                  %{
                    "player_name" => player_name(players, get(call, :player)),
                    "stock" => get(call, :stock),
                    "stance" => get(call, :stance),
                    "confidence" => get(call, :confidence),
                    "thesis" => rewrite_public_text(get(call, :thesis, ""), players)
                  }
                end),
              "whisper_graph" =>
                Enum.map(whisper_graph, fn entry ->
                  %{
                    "from" => player_name(players, get(entry, :from)),
                    "to" => player_name(players, get(entry, :to))
                  }
                end),
              "your_whispers" =>
                Enum.map(visible_whispers, fn entry ->
                  %{
                    "from" => player_name(players, get(entry, :from)),
                    "to" => player_name(players, get(entry, :to)),
                    "message" => get(entry, :message)
                  }
                end)
            }
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          actor_id = get(frame.world, :active_actor_id)

          filtered =
            frame.recent_events
            |> Enum.take(-15)
            |> Enum.filter(&event_visible?(&1, actor_id))
            |> Enum.map(&sanitize_event(&1, actor_id))

          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: filtered
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        STOCK MARKET ARENA RULES:
        - You are a trader competing to finish with the highest portfolio value after 10 rounds.
        - Use exactly one tool call per turn.
        - Discussion has two passes each round:
          1. Public signal pass: either broadcast a structured bullish/bearish market call or make a public statement.
          2. Private whisper pass: whisper to one trader or deliberately pass.
        - Public market calls influence prices, so persuasive signaling is part of the game.
        - Traders build or lose public credibility. Accurate calls raise your reputation and make future calls move markets more.
        - Private tips are real but noisy. They are secret. Decide what to reveal, distort, or hide.
        - Use trader names in public discussion, not raw ids like player_2.
        - Use ids only when a tool requires a `to_id` or `player_id`.
        - During trading, place exactly one trade: buy, sell, short, cover, or hold.
        - Public standings show total portfolio value and trader reputation, not exact books.
        - Shorting is allowed but capped by your equity. Bearish reasoning should be actionable, not just rhetorical.
        - Optimize for both edge and narrative pressure: who the table believes can matter almost as much as who is right.
        """
      },
      section_order: [
        :world_state,
        :role_info,
        :discussion_log,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    GameRunner.build_default_opts(projector_opts(), overrides,
      game_name: "Stock Market Arena",
      max_turns: @default_max_turns,
      terminal?: &terminal?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    GameRunner.run(state, modules(), &default_opts/1, opts,
      print_setup: fn s ->
        IO.puts(
          "Starting Stock Market game with #{map_size(get(s.world, :players, %{}))} traders"
        )

        print_initial_state(s.world)
      end,
      print_result: &print_game_result/1
    )
  end

  @spec run_multi_model(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run_multi_model(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    GameRunner.run_multi_model(state, modules(), &default_opts/1, opts,
      print_setup: fn s ->
        IO.puts(
          "Starting Stock Market game with #{map_size(get(s.world, :players, %{}))} traders (multi-model)"
        )

        print_initial_state(s.world)
      end,
      print_result: &print_game_result/1,
      announce_turn: &announce_turn/2,
      print_step: &print_step/2,
      transcript_detail: &transcript_detail/1,
      transcript_game_over_extra: &transcript_game_over_extra/1
    )
  end

  defp build_market_view(world, actor_id) do
    players = get(world, :players, %{})
    stocks = get(world, :stocks, %{})
    market_calls = get(world, :market_calls, [])

    stock_summary =
      Market.stock_names()
      |> Enum.map(fn ticker ->
        stock = Map.get(stocks, ticker, %{})
        price = get(stock, :price, 0)
        history = get(stock, :history, [])
        config = Map.get(Market.stock_config(), ticker, %{})
        prev_price = if length(history) >= 2, do: Enum.at(history, -2), else: price

        %{
          "ticker" => ticker,
          "type" => Map.get(config, :label, "stock"),
          "price" => price,
          "change" => Float.round(price - prev_price, 2),
          "history_length" => length(history)
        }
      end)

    player_summary =
      players
      |> Enum.sort_by(fn {id, _p} -> id end)
      |> Enum.map(fn {id, player} ->
        %{
          "id" => id,
          "name" => player_name(players, id),
          "reputation" => get(player, :reputation, Market.initial_reputation()),
          "total_portfolio_value" => Float.round(Market.portfolio_value(player, stocks) * 1.0, 2)
        }
      end)

    %{
      "phase" => get(world, :phase),
      "round" => get(world, :round),
      "max_rounds" => get(world, :max_rounds),
      "discussion_round" => get(world, :discussion_round, 0),
      "discussion_round_limit" => get(world, :discussion_round_limit, 0),
      "active_player" => %{
        "id" => get(world, :active_actor_id),
        "name" => player_name(players, get(world, :active_actor_id))
      },
      "you" => %{"id" => actor_id, "name" => player_name(players, actor_id)},
      "stocks" => stock_summary,
      "players" => player_summary,
      "market_news" => get(world, :market_news, ""),
      "public_market_calls" =>
        Enum.map(market_calls, fn call ->
          %{
            "player_name" => player_name(players, get(call, :player)),
            "stock" => get(call, :stock),
            "stance" => get(call, :stance),
            "confidence" => get(call, :confidence),
            "reputation" => get(call, :reputation, Market.initial_reputation())
          }
        end),
      "last_round_summary" =>
        format_round_summary(List.last(get(world, :round_summaries, [])), players)
    }
  end

  defp build_private_info(world, actor_id) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    stocks = get(world, :stocks, %{})

    cash = get(actor, :cash, 0)
    portfolio = get(actor, :portfolio, %{})
    short_book = get(actor, :short_book, %{})
    tips = get(actor, :tips_received, [])
    total = Market.portfolio_value(actor, stocks)

    holdings =
      Enum.map(Market.stock_names(), fn ticker ->
        shares = Map.get(portfolio, ticker, 0)
        price = Market.get_stock_price(stocks, ticker)

        %{
          "stock" => ticker,
          "long_shares" => shares,
          "short_shares" => Map.get(short_book, ticker, 0),
          "current_price" => price,
          "value" => Float.round(shares * price * 1.0, 2)
        }
      end)

    recent_trades =
      actor
      |> get(:trade_history, [])
      |> Enum.take(-5)
      |> Enum.map(fn trade ->
        %{
          "round" => get(trade, :round),
          "action" => get(trade, :action),
          "stock" => get(trade, :stock),
          "quantity" => get(trade, :quantity),
          "price" => get(trade, :price)
        }
      end)

    %{
      "your_id" => actor_id,
      "your_name" => player_name(players, actor_id),
      "cash" => Float.round(cash * 1.0, 2),
      "reputation" => get(actor, :reputation, Market.initial_reputation()),
      "total_portfolio_value" => Float.round(total * 1.0, 2),
      "holdings" => holdings,
      "private_tips" =>
        Enum.map(tips, fn tip ->
          %{
            "round" => get(tip, :round),
            "stock" => get(tip, :stock),
            "hint" => get(tip, :hint_text),
            "bias" => get(tip, :bias),
            "catalyst" => get(tip, :catalyst),
            "conviction" => get(tip, :conviction),
            "range" => get(tip, :price_range)
          }
        end),
      "recent_trades" => recent_trades,
      "description" =>
        "You are trying to beat the field on a mix of private information, public persuasion, and disciplined execution."
    }
  end

  @private_events ~w(tip_received skip_whisper)
  @whisper_events ~w(send_whisper)

  defp event_visible?(event, _actor_id) when not is_map(event), do: false

  defp event_visible?(event, actor_id) do
    kind = event_kind(event)

    cond do
      kind in @private_events ->
        event_player_id(event) == actor_id

      kind in @whisper_events ->
        payload = event_payload(event)

        from =
          Map.get(
            payload,
            :from_id,
            Map.get(
              payload,
              "from_id",
              Map.get(payload, :player_id, Map.get(payload, "player_id"))
            )
          )

        to = Map.get(payload, :to_id, Map.get(payload, "to_id"))
        from == actor_id or to == actor_id

      kind == "action_rejected" ->
        event_player_id(event) == actor_id

      true ->
        true
    end
  end

  defp sanitize_event(event, _actor_id) when not is_map(event), do: event

  defp sanitize_event(event, _actor_id) do
    kind = event_kind(event)
    payload = event_payload(event)

    case kind do
      "market_news_generated" ->
        sanitized_payload =
          payload
          |> Map.put(:tips_distributed, "some traders received private tips")
          |> Map.put("tips_distributed", "some traders received private tips")

        put_payload(event, sanitized_payload)

      _ ->
        event
    end
  end

  defp transcript_detail(world) do
    phase = get(world, :phase)
    players = get(world, :players, %{})

    case phase do
      "discussion" ->
        latest_tape = List.last(get(world, :discussion_transcript, []))
        latest_whisper = List.last(get(world, :whisper_log, []))

        %{}
        |> maybe_put(
          :latest_public_signal,
          if(latest_tape,
            do: %{
              player: player_name(players, get(latest_tape, :player)),
              type: get(latest_tape, :type, "statement"),
              text: get(latest_tape, :statement)
            },
            else: nil
          )
        )
        |> maybe_put(
          :latest_whisper,
          if(latest_whisper,
            do: %{
              from: player_name(players, get(latest_whisper, :from)),
              to: player_name(players, get(latest_whisper, :to))
            },
            else: nil
          )
        )

      "trading" ->
        case Map.to_list(get(world, :trades, %{})) |> List.last() do
          {player_id, trade} ->
            %{
              latest_trade: %{
                player: player_name(players, player_id),
                action: get(trade, :action),
                stock: get(trade, :stock),
                quantity: get(trade, :quantity)
              }
            }

          nil ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp transcript_game_over_extra(world) do
    players = get(world, :players, %{})
    stocks = get(world, :stocks, %{})

    %{
      round: get(world, :round),
      final_stocks: stocks,
      market_call_history: get(world, :market_call_history, []),
      round_summaries: get(world, :round_summaries, []),
      performance: Performance.summarize(world),
      final_players:
        Enum.into(players, %{}, fn {id, player} ->
          {id,
           %{
             name: get(player, :name, id),
             cash: get(player, :cash),
             portfolio: get(player, :portfolio),
             short_book: get(player, :short_book),
             reputation: get(player, :reputation),
             total_value: Market.portfolio_value(player, stocks)
           }}
        end)
    }
  end

  defp terminal?(state), do: get(state.world, :status) in ["game_over"]

  defp announce_turn(turn, state) do
    actor_id = get(state.world, :active_actor_id)
    players = get(state.world, :players, %{})
    phase = get(state.world, :phase)
    round = get(state.world, :round, 1)
    discussion_round = get(state.world, :discussion_round, 0)

    suffix =
      if phase == "discussion" do
        " discussion_round=#{discussion_round}"
      else
        ""
      end

    IO.puts(
      "Step #{turn} | round=#{round} phase=#{phase} actor=#{player_name(players, actor_id)} (#{actor_id})#{suffix}"
    )
  end

  defp print_step(_turn, %{state: next_state}) do
    world = next_state.world
    players = get(world, :players, %{})

    case get(world, :phase) do
      "discussion" ->
        case List.last(get(world, :discussion_transcript, [])) do
          nil ->
            case List.last(get(world, :whisper_log, [])) do
              nil ->
                :ok

              whisper ->
                IO.puts(
                  "  #{player_name(players, get(whisper, :from))} whispered to #{player_name(players, get(whisper, :to))}"
                )
            end

          entry ->
            IO.puts("  [#{player_name(players, get(entry, :player))}] #{get(entry, :statement)}")
        end

      "trading" ->
        case Map.to_list(get(world, :trades, %{})) |> List.last() do
          {player_id, trade} ->
            case get(trade, :action) do
              "hold" ->
                IO.puts("  #{player_name(players, player_id)} holds")

              action ->
                IO.puts(
                  "  #{player_name(players, player_id)} #{action}s #{get(trade, :quantity)} #{get(trade, :stock)}"
                )
            end

          nil ->
            :ok
        end

      "game_over" ->
        IO.puts("  Game over! Winner: #{player_name(players, get(world, :winner))}")

      _ ->
        :ok
    end
  end

  defp print_step(_turn, _result), do: :ok

  defp print_initial_state(world) do
    stocks = get(world, :stocks, %{})
    players = get(world, :players, %{})

    IO.puts("Opening prices:")

    Market.stock_names()
    |> Enum.each(fn ticker ->
      price = Market.get_stock_price(stocks, ticker)
      label = Market.stock_config() |> Map.get(ticker, %{}) |> Map.get(:label, "stock")
      IO.puts("  #{ticker} (#{label}): $#{price}")
    end)

    IO.puts("\nTraders:")

    players
    |> Enum.sort_by(fn {id, _player} -> id end)
    |> Enum.each(fn {id, player} ->
      IO.puts("  #{get(player, :name, id)} (#{id}) starts with $#{Market.initial_cash()}")
    end)

    IO.puts("\nRound 1 news: #{get(world, :market_news, "")}\n")
  end

  defp print_game_result(world) do
    winner = get(world, :winner)
    players = get(world, :players, %{})
    stocks = get(world, :stocks, %{})
    performance = Performance.summarize(world)

    IO.puts("Winner: #{player_name(players, winner)} (#{winner})")
    IO.puts("\nFinal stock prices:")

    Market.stock_names()
    |> Enum.each(fn ticker ->
      stock = Map.get(stocks, ticker, %{})
      price = get(stock, :price, 0)
      history = get(stock, :history, [])
      start_price = List.first(history) || price
      change = Float.round(price - start_price, 2)
      pct = if start_price > 0, do: Float.round(change / start_price * 100, 1), else: 0.0

      IO.puts(
        "  #{ticker}: $#{price} (#{if change >= 0, do: "+", else: ""}#{change}, #{if pct >= 0, do: "+", else: ""}#{pct}%)"
      )
    end)

    IO.puts("\nFinal standings:")

    {_values, standings} = Market.calculate_standings(players, stocks)

    Enum.each(standings, fn standing ->
      player = Map.get(players, standing.player, %{})
      cash = get(player, :cash, 0)
      portfolio = get(player, :portfolio, %{})
      short_book = get(player, :short_book, %{})

      holdings =
        Market.stock_names()
        |> Enum.filter(fn ticker -> Map.get(portfolio, ticker, 0) > 0 end)
        |> Enum.map(fn ticker -> "#{Map.get(portfolio, ticker, 0)} #{ticker}" end)
        |> Enum.join(", ")

      shorts =
        Market.stock_names()
        |> Enum.filter(fn ticker -> Map.get(short_book, ticker, 0) > 0 end)
        |> Enum.map(fn ticker -> "#{Map.get(short_book, ticker, 0)} #{ticker}" end)
        |> Enum.join(", ")

      IO.puts(
        "  #{standing.rank}. #{get(player, :name, standing.player)}: $#{Float.round(standing.total_value * 1.0, 2)} " <>
          "(cash: $#{Float.round(cash * 1.0, 2)}, rep: #{get(player, :reputation, Market.initial_reputation())}, " <>
          "longs: #{if holdings == "", do: "flat", else: holdings}, shorts: #{if shorts == "", do: "flat", else: shorts})"
      )
    end)

    IO.puts("\nPerformance summary:")

    performance.players
    |> Enum.sort_by(fn {_id, metrics} -> get(metrics, :final_value, 0) end, :desc)
    |> Enum.each(fn {_player_id, metrics} ->
      IO.puts(
        "  #{metrics.name}: value=$#{Float.round(metrics.final_value * 1.0, 2)} " <>
          "return=#{metrics.return_pct}% rep=#{metrics.final_reputation} calls=#{metrics.market_calls_made} " <>
          "accurate_calls=#{metrics.accurate_calls} short_trades=#{metrics.short_trades} whispers=#{metrics.whispers_sent}"
      )
    end)
  end

  defp format_round_summary(nil, _players), do: nil

  defp format_round_summary(summary, _players) do
    %{
      "round" => get(summary, :round),
      "leader" => get(summary, :leader),
      "biggest_move" => get(summary, :biggest_move),
      "trade_count" => get(summary, :trade_count, 0),
      "market_call_count" => get(summary, :market_call_count, 0),
      "accurate_calls" => get(summary, :accurate_calls, 0),
      "reputation_updates" => get(summary, :reputation_updates, [])
    }
  end

  defp player_name(_players, nil), do: nil

  defp player_name(players, player_id) do
    players
    |> Map.get(player_id, %{})
    |> get(:name, player_id)
  end

  defp rewrite_public_text(text, players) when is_binary(text) do
    Enum.reduce(players, text, fn {player_id, player}, acc ->
      String.replace(acc, player_id, get(player, :name, player_id))
    end)
  end

  defp rewrite_public_text(text, _players), do: text
end
