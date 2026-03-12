defmodule LemonSim.Examples.StockMarketUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.StockMarket
  alias LemonSim.Examples.StockMarket.{Events, Updater}

  test "discussion uses a public call pass and a whisper pass before trading" do
    state = StockMarket.initial_state(player_count: 4)
    first_order = state.world.turn_order

    {:ok, after_calls, {:decide, _}} =
      Enum.reduce(first_order, {:ok, state, nil}, fn actor_id, {:ok, acc_state, _} ->
        Updater.apply_event(
          acc_state,
          Events.broadcast_market_call(
            actor_id,
            "NOVA",
            "bullish",
            3,
            "#{actor_id} likes momentum"
          ),
          []
        )
      end)

    assert after_calls.world.phase == "discussion"
    assert after_calls.world.discussion_round == 2
    assert length(after_calls.world.market_calls) == 4

    second_order = after_calls.world.turn_order

    {:ok, after_whispers, {:decide, _}} =
      Enum.reduce(second_order, {:ok, after_calls, nil}, fn actor_id, {:ok, acc_state, _} ->
        Updater.apply_event(acc_state, Events.skip_whisper(actor_id), [])
      end)

    assert after_whispers.world.phase == "trading"
    assert after_whispers.world.active_actor_id == List.first(after_whispers.world.turn_order)
  end

  test "resolving a round records reputation updates and supports short trades" do
    state = StockMarket.initial_state(player_count: 4)
    players = state.world.players
    round = state.world.round
    trading_order = players |> Map.keys() |> Enum.sort()
    initial_reputation = players["player_1"].reputation

    state =
      %{
        state
        | world: %{
            state.world
            | phase: "trading",
              turn_order: trading_order,
              active_actor_id: List.first(trading_order),
              market_calls: [
                %{
                  round: round,
                  player: "player_1",
                  stock: "NOVA",
                  stance: "bullish",
                  confidence: 4,
                  thesis: "AI demand",
                  reputation: initial_reputation
                },
                %{
                  round: round,
                  player: "player_2",
                  stock: "SAFE",
                  stance: "bearish",
                  confidence: 2,
                  thesis: "Duration risk",
                  reputation: players["player_2"].reputation
                }
              ]
          }
      }

    {:ok, next_state, {:decide, _}} =
      Enum.reduce(trading_order, {:ok, state, nil}, fn actor_id, {:ok, acc_state, _} ->
        event =
          if actor_id == "player_1" do
            Events.place_trade(actor_id, "short", "PULSE", 5)
          else
            Events.place_trade(actor_id, "hold", "", 0)
          end

        Updater.apply_event(acc_state, event, [])
      end)

    assert next_state.world.round == 2
    assert next_state.world.phase == "discussion"
    assert next_state.world.market_calls == []
    assert length(next_state.world.market_call_history) == 2
    assert length(next_state.world.round_summaries) == 1
    assert List.last(next_state.world.round_summaries).market_call_count == 2
    assert List.last(next_state.world.round_summaries).trade_count == 1
    assert next_state.world.players["player_1"].reputation != initial_reputation
    assert Enum.any?(next_state.world.players["player_1"].trade_history, &(&1.action == "short"))
  end
end
