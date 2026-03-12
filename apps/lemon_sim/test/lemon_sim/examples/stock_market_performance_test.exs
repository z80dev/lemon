defmodule LemonSim.Examples.StockMarketPerformanceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.StockMarket.Performance

  test "summarizes directional calls, whispers, and trade outcomes" do
    world = %{
      winner: "player_1",
      players: %{
        "player_1" => %{
          name: "Alice",
          model: "gemini/gemini-2.5-flash",
          cash: 9_800,
          reputation: 58,
          portfolio: %{"NOVA" => 4, "PULSE" => 0, "SAFE" => 0, "TERRA" => 0, "VISTA" => 0},
          short_book: %{"NOVA" => 0, "PULSE" => 0, "SAFE" => 0, "TERRA" => 0, "VISTA" => 0},
          trade_history: [%{round: 1, action: "buy", stock: "NOVA", quantity: 4, price: 50.0}]
        },
        "player_2" => %{
          name: "Bram",
          model: "gpt-5.3-codex",
          cash: 10_300,
          reputation: 61,
          portfolio: %{"NOVA" => 0, "PULSE" => 0, "SAFE" => 0, "TERRA" => 0, "VISTA" => 0},
          short_book: %{"NOVA" => 0, "PULSE" => 4, "SAFE" => 0, "TERRA" => 0, "VISTA" => 0},
          trade_history: [%{round: 1, action: "short", stock: "PULSE", quantity: 4, price: 36.0}]
        }
      },
      stocks: %{
        "NOVA" => %{price: 60.0, history: [50.0, 60.0], volatility: 2.0},
        "PULSE" => %{price: 28.0, history: [36.0, 28.0], volatility: 2.4},
        "TERRA" => %{price: 24.0, history: [30.0, 24.0], volatility: 1.0},
        "SAFE" => %{price: 20.0, history: [20.0, 20.0], volatility: 0.3},
        "VISTA" => %{price: 42.0, history: [42.0, 42.0], volatility: 1.5}
      },
      market_call_history: [
        %{
          round: 1,
          player: "player_1",
          stock: "NOVA",
          stance: "bullish",
          confidence: 4,
          thesis: "AI demand"
        },
        %{
          round: 1,
          player: "player_2",
          stock: "PULSE",
          stance: "bearish",
          confidence: 3,
          thesis: "Macro slowdown"
        }
      ],
      round_summaries: [
        %{
          round: 1,
          price_changes: %{
            "NOVA" => %{change: 10.0},
            "PULSE" => %{change: -8.0},
            "TERRA" => %{change: -6.0},
            "SAFE" => %{change: 0.0},
            "VISTA" => %{change: 0.0}
          }
        }
      ],
      whisper_history: [
        %{round: 1, from: "player_1", to: "player_2", message: "Watch NOVA"}
      ]
    }

    summary = Performance.summarize(world)

    assert summary.benchmark_focus ==
             "private-information trading, public signaling, and directional accuracy"

    assert summary.players["player_1"].won
    assert summary.players["player_1"].market_calls_made == 1
    assert summary.players["player_1"].accurate_calls == 1
    assert summary.players["player_1"].profitable_trades == 1
    assert summary.players["player_1"].whispers_sent == 1
    assert summary.players["player_1"].final_reputation == 58

    assert summary.players["player_2"].market_calls_made == 1
    assert summary.players["player_2"].accurate_calls == 1
    assert summary.players["player_2"].profitable_trades == 1
    assert summary.players["player_2"].short_trades == 1

    assert summary.models["gemini/gemini-2.5-flash"].wins == 1
    assert summary.models["gpt-5.3-codex"].accurate_calls == 1
    assert summary.models["gpt-5.3-codex"].short_trades == 1
  end
end
