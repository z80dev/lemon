defmodule LemonSim.Examples.Skirmish.Outcome do
  @moduledoc false

  @enforce_keys [:roll, :chance, :damage, :defender_hp, :hit?]
  defstruct roll: 0,
            chance: 0,
            damage: 0,
            defender_hp: 0,
            hit?: false,
            defender_died?: false,
            winner: nil

  @type t :: %__MODULE__{
          roll: pos_integer(),
          chance: pos_integer(),
          damage: non_neg_integer(),
          defender_hp: non_neg_integer(),
          hit?: boolean(),
          defender_died?: boolean(),
          winner: String.t() | nil
        }

  @spec attack(pos_integer(), pos_integer(), pos_integer(), non_neg_integer()) :: t()
  def attack(roll, chance, attack_damage, defender_hp_before)
      when is_integer(roll) and roll > 0 and is_integer(chance) and chance > 0 and
             is_integer(attack_damage) and attack_damage >= 0 and is_integer(defender_hp_before) and
             defender_hp_before >= 0 do
    hit? = roll <= chance
    damage = if hit?, do: attack_damage, else: 0
    defender_hp = max(defender_hp_before - damage, 0)

    %__MODULE__{
      roll: roll,
      chance: chance,
      damage: damage,
      defender_hp: defender_hp,
      hit?: hit?,
      defender_died?: defender_hp == 0
    }
  end

  @spec with_winner(t(), String.t() | nil) :: t()
  def with_winner(%__MODULE__{} = outcome, winner) when is_binary(winner) or is_nil(winner) do
    %{outcome | winner: winner}
  end

  @spec winner(map()) :: String.t() | nil
  def winner(units) when is_map(units) do
    living_teams =
      units
      |> Map.values()
      |> Enum.filter(&(alive?(&1) and hp(&1) > 0))
      |> Enum.map(&team/1)
      |> Enum.uniq()

    case living_teams do
      [team] -> team
      _ -> nil
    end
  end

  defp alive?(unit), do: status(unit) != "dead"

  defp hp(unit), do: Map.get(unit, :hp, Map.get(unit, "hp", 0))
  defp team(unit), do: Map.get(unit, :team, Map.get(unit, "team"))
  defp status(unit), do: Map.get(unit, :status, Map.get(unit, "status", "alive"))
end
