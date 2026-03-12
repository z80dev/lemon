defmodule LemonSim.Examples.Auction.Items do
  @moduledoc """
  Item definitions, set bonus calculations, and scoring logic for the Auction House game.
  """

  @gems [
    %{name: "Ruby", category: "gem", base_value: 10},
    %{name: "Sapphire", category: "gem", base_value: 8},
    %{name: "Emerald", category: "gem", base_value: 12},
    %{name: "Diamond", category: "gem", base_value: 15}
  ]

  @artifacts [
    %{name: "Crown", category: "artifact", base_value: 15},
    %{name: "Scepter", category: "artifact", base_value: 12},
    %{name: "Chalice", category: "artifact", base_value: 8},
    %{name: "Amulet", category: "artifact", base_value: 20}
  ]

  @scrolls [
    %{name: "Fire Scroll", category: "scroll", base_value: 7},
    %{name: "Ice Scroll", category: "scroll", base_value: 5},
    %{name: "Lightning Scroll", category: "scroll", base_value: 10},
    %{name: "Shadow Scroll", category: "scroll", base_value: 3}
  ]

  @all_items @gems ++ @artifacts ++ @scrolls

  @secret_objectives [
    "collect_2_gems",
    "collect_2_artifacts",
    "spend_least_gold",
    "win_most_auctions",
    "collect_3_categories"
  ]

  @doc """
  Returns all item definitions.
  """
  @spec all_items() :: [map()]
  def all_items, do: @all_items

  @doc """
  Returns the list of possible secret objectives.
  """
  @spec secret_objectives() :: [String.t()]
  def secret_objectives, do: @secret_objectives

  @doc """
  Generates a shuffled auction schedule of 10 items (8 rounds, some rounds have 2 items).
  Uses the provided seed for deterministic shuffling.
  """
  @spec generate_schedule(integer()) :: [map()]
  def generate_schedule(seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    # Pick 10 items from the pool: shuffle all 12, take 10
    @all_items
    |> Enum.shuffle()
    |> Enum.take(10)
  end

  @doc """
  Returns which rounds have 2 items (0-indexed round numbers).
  For 10 items across 8 rounds, rounds 2 and 5 get 2 items.
  """
  @spec items_per_round() :: [pos_integer()]
  def items_per_round do
    # 8 rounds: rounds 1-8. Most have 1 item, rounds 3 and 6 have 2 items.
    # That gives 6*1 + 2*2 = 10 items total.
    [1, 1, 2, 1, 1, 2, 1, 1]
  end

  @doc """
  Assigns secret objectives to players randomly using the given seed.
  """
  @spec assign_objectives([String.t()], integer()) :: %{String.t() => String.t()}
  def assign_objectives(player_ids, seed) do
    :rand.seed(:exsss, {seed + 100, seed + 101, seed + 102})

    shuffled_objectives = Enum.shuffle(@secret_objectives)

    player_ids
    |> Enum.with_index()
    |> Enum.into(%{}, fn {player_id, idx} ->
      objective = Enum.at(shuffled_objectives, rem(idx, length(shuffled_objectives)))
      {player_id, objective}
    end)
  end

  @doc """
  Calculates the final score for a player given their items, gold, secret objective,
  and game-wide stats.
  """
  @spec calculate_score(map(), map()) :: map()
  def calculate_score(player, game_stats) do
    items = Map.get(player, :items, [])
    gold = Map.get(player, :gold, 0)
    objective = Map.get(player, :secret_objective, "")

    item_value = Enum.reduce(items, 0, fn item, acc -> acc + get_base_value(item) end)
    set_bonus = calculate_set_bonuses(items)
    gold_bonus = div(gold, 10)
    objective_bonus = calculate_objective_bonus(objective, player, game_stats)

    %{
      item_value: item_value,
      set_bonus: set_bonus,
      gold_bonus: gold_bonus,
      objective_bonus: objective_bonus,
      total: item_value + set_bonus + gold_bonus + objective_bonus
    }
  end

  @doc """
  Calculates set bonuses for a list of items.
  """
  @spec calculate_set_bonuses([map()]) :: non_neg_integer()
  def calculate_set_bonuses(items) do
    categories = Enum.map(items, fn item -> get_category(item) end)
    category_counts = Enum.frequencies(categories)

    gem_count = Map.get(category_counts, "gem", 0)
    artifact_count = Map.get(category_counts, "artifact", 0)
    scroll_count = Map.get(category_counts, "scroll", 0)

    bonus = 0

    # 3 gems = +15
    bonus = if gem_count >= 3, do: bonus + 15, else: bonus
    # 3 artifacts = +20
    bonus = if artifact_count >= 3, do: bonus + 20, else: bonus
    # 3 scrolls = +10
    bonus = if scroll_count >= 3, do: bonus + 10, else: bonus

    # All 4 of one category = +40
    bonus =
      if gem_count >= 4 or artifact_count >= 4 or scroll_count >= 4 do
        bonus + 40
      else
        bonus
      end

    # One of each category = +12
    bonus =
      if gem_count >= 1 and artifact_count >= 1 and scroll_count >= 1 do
        bonus + 12
      else
        bonus
      end

    bonus
  end

  defp calculate_objective_bonus("collect_2_gems", player, _stats) do
    gem_count =
      player
      |> Map.get(:items, [])
      |> Enum.count(fn item -> get_category(item) == "gem" end)

    if gem_count >= 2, do: 15, else: 0
  end

  defp calculate_objective_bonus("collect_2_artifacts", player, _stats) do
    artifact_count =
      player
      |> Map.get(:items, [])
      |> Enum.count(fn item -> get_category(item) == "artifact" end)

    if artifact_count >= 2, do: 15, else: 0
  end

  defp calculate_objective_bonus("spend_least_gold", player, stats) do
    player_spent = Map.get(stats, :gold_spent, %{})
    player_id = Map.get(player, :id)

    if player_id do
      my_spent = Map.get(player_spent, player_id, 0)
      min_spent = player_spent |> Map.values() |> Enum.min(fn -> 0 end)

      if my_spent <= min_spent, do: 15, else: 0
    else
      0
    end
  end

  defp calculate_objective_bonus("win_most_auctions", player, stats) do
    auction_wins = Map.get(stats, :auction_wins, %{})
    player_id = Map.get(player, :id)

    if player_id do
      my_wins = Map.get(auction_wins, player_id, 0)
      max_wins = auction_wins |> Map.values() |> Enum.max(fn -> 0 end)

      if my_wins >= max_wins and my_wins > 0, do: 15, else: 0
    else
      0
    end
  end

  defp calculate_objective_bonus("collect_3_categories", player, _stats) do
    categories =
      player
      |> Map.get(:items, [])
      |> Enum.map(fn item -> get_category(item) end)
      |> Enum.uniq()
      |> length()

    if categories >= 3, do: 15, else: 0
  end

  defp calculate_objective_bonus(_objective, _player, _stats), do: 0

  defp get_base_value(item) when is_map(item) do
    Map.get(item, :base_value, Map.get(item, "base_value", 0))
  end

  defp get_category(item) when is_map(item) do
    Map.get(item, :category, Map.get(item, "category", "unknown"))
  end

  @doc """
  Returns a human-readable description of a secret objective.
  """
  @spec objective_description(String.t()) :: String.t()
  def objective_description("collect_2_gems"), do: "Collect 2 or more gems (+15 bonus)"
  def objective_description("collect_2_artifacts"), do: "Collect 2 or more artifacts (+15 bonus)"
  def objective_description("spend_least_gold"), do: "Spend the least gold overall (+15 bonus)"
  def objective_description("win_most_auctions"), do: "Win the most auctions (+15 bonus)"

  def objective_description("collect_3_categories"),
    do: "Collect items from 3 different categories (+15 bonus)"

  def objective_description(_), do: "Unknown objective"

  @doc """
  Returns a wealth indicator string based on gold amount.
  """
  @spec wealth_indicator(non_neg_integer()) :: String.t()
  def wealth_indicator(gold) when gold >= 80, do: "high"
  def wealth_indicator(gold) when gold >= 40, do: "medium"
  def wealth_indicator(_gold), do: "low"
end
