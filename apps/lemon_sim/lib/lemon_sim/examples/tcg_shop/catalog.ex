defmodule LemonSim.Examples.TcgShop.Catalog do
  @moduledoc false

  @lines [
    %{
      id: "pokemon_booster_box",
      franchise: "Pokemon",
      name: "Pokemon Booster Box",
      category: "sealed",
      unit_cost: 94.0,
      market_price: 142.0,
      suggested_price: 149.99,
      velocity: 1.35,
      volatility: 0.18,
      supplier_delay_days: 2
    },
    %{
      id: "pokemon_elite_trainer_box",
      franchise: "Pokemon",
      name: "Pokemon Elite Trainer Box",
      category: "sealed",
      unit_cost: 31.0,
      market_price: 49.0,
      suggested_price: 54.99,
      velocity: 1.15,
      volatility: 0.12,
      supplier_delay_days: 2
    },
    %{
      id: "yugioh_core_box",
      franchise: "Yu-Gi-Oh!",
      name: "Yu-Gi-Oh! Core Booster Box",
      category: "sealed",
      unit_cost: 52.0,
      market_price: 73.0,
      suggested_price: 79.99,
      velocity: 0.9,
      volatility: 0.16,
      supplier_delay_days: 3
    },
    %{
      id: "one_piece_booster_box",
      franchise: "One Piece",
      name: "One Piece Booster Box",
      category: "sealed",
      unit_cost: 74.0,
      market_price: 123.0,
      suggested_price: 129.99,
      velocity: 1.45,
      volatility: 0.24,
      supplier_delay_days: 4
    },
    %{
      id: "dragon_ball_fusion_box",
      franchise: "Dragon Ball Super",
      name: "Dragon Ball Super Fusion World Box",
      category: "sealed",
      unit_cost: 58.0,
      market_price: 88.0,
      suggested_price: 94.99,
      velocity: 0.72,
      volatility: 0.2,
      supplier_delay_days: 3
    },
    %{
      id: "card_sleeves",
      franchise: "Accessories",
      name: "Premium Card Sleeves",
      category: "accessory",
      unit_cost: 2.1,
      market_price: 5.0,
      suggested_price: 6.49,
      velocity: 1.7,
      volatility: 0.04,
      supplier_delay_days: 1
    },
    %{
      id: "toploaders",
      franchise: "Accessories",
      name: "Toploaders 25ct",
      category: "accessory",
      unit_cost: 2.6,
      market_price: 5.5,
      suggested_price: 6.99,
      velocity: 1.25,
      volatility: 0.05,
      supplier_delay_days: 1
    }
  ]

  @franchises ["Pokemon", "Yu-Gi-Oh!", "One Piece", "Dragon Ball Super", "Accessories"]

  def lines, do: @lines
  def franchises, do: @franchises

  def catalog do
    Enum.into(@lines, %{}, fn line -> {line.id, line} end)
  end

  def line(id), do: Map.get(catalog(), id)

  def release_calendar(max_days) do
    [
      %{
        day: 3,
        franchise: "Pokemon",
        title: "Prerelease weekend demand spike",
        demand_bonus: 0.35
      },
      %{
        day: 5,
        franchise: "One Piece",
        title: "Allocation rumor and buyout wave",
        demand_bonus: 0.45
      },
      %{day: 8, franchise: "Yu-Gi-Oh!", title: "Regional decklist shakeup", demand_bonus: 0.25},
      %{
        day: 11,
        franchise: "Dragon Ball Super",
        title: "Starter deck league night",
        demand_bonus: 0.3
      },
      %{
        day: max(14, div(max_days, 2)),
        franchise: "Pokemon",
        title: "New set launch",
        demand_bonus: 0.5
      }
    ]
    |> Enum.filter(&(&1.day <= max_days))
  end
end
