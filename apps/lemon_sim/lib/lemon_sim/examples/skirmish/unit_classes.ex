defmodule LemonSim.Examples.Skirmish.UnitClasses do
  @moduledoc false

  @class_stats %{
    "scout" => %{
      hp: 5,
      max_hp: 5,
      ap: 3,
      max_ap: 3,
      attack_range: 2,
      attack_damage: 2,
      attack_chance: 85,
      sight_range: 5,
      abilities: [:sprint],
      class: "scout"
    },
    "soldier" => %{
      hp: 8,
      max_hp: 8,
      ap: 2,
      max_ap: 2,
      attack_range: 3,
      attack_damage: 3,
      attack_chance: 90,
      sight_range: 4,
      abilities: [],
      class: "soldier"
    },
    "heavy" => %{
      hp: 14,
      max_hp: 14,
      ap: 2,
      max_ap: 2,
      attack_range: 1,
      attack_damage: 5,
      attack_chance: 95,
      sight_range: 3,
      abilities: [],
      class: "heavy"
    },
    "sniper" => %{
      hp: 5,
      max_hp: 5,
      ap: 2,
      max_ap: 2,
      attack_range: 6,
      attack_damage: 4,
      attack_chance: 70,
      sight_range: 7,
      abilities: [],
      class: "sniper"
    },
    "medic" => %{
      hp: 7,
      max_hp: 7,
      ap: 2,
      max_ap: 2,
      attack_range: 2,
      attack_damage: 2,
      attack_chance: 80,
      sight_range: 4,
      abilities: [:heal],
      heal_amount: 3,
      class: "medic"
    }
  }

  @spec class_stats(String.t()) :: map() | nil
  def class_stats(class_name) when is_binary(class_name) do
    Map.get(@class_stats, class_name)
  end

  @spec build_unit(String.t(), String.t(), String.t(), map()) :: map()
  def build_unit(unit_id, team, class_name, %{x: _x, y: _y} = pos)
      when is_binary(unit_id) and is_binary(team) and is_binary(class_name) do
    stats = class_stats(class_name) || raise "unknown unit class: #{class_name}"

    stats
    |> Map.merge(%{
      team: team,
      pos: pos,
      status: "alive",
      cover?: false
    })
  end

  @spec default_squad() :: [String.t()]
  def default_squad do
    ["soldier", "scout", "medic"]
  end

  @spec all_classes() :: [String.t()]
  def all_classes do
    Map.keys(@class_stats)
  end

  @spec has_ability?(map(), atom()) :: boolean()
  def has_ability?(%{abilities: abilities}, ability) when is_atom(ability) do
    ability in abilities
  end

  def has_ability?(_unit, _ability), do: false
end
