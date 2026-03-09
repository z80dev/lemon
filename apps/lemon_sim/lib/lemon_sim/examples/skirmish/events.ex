defmodule LemonSim.Examples.Skirmish.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  @spec move_requested(String.t(), integer(), integer()) :: Event.t()
  def move_requested(unit_id, x, y) do
    Event.new("move_requested", %{"unit_id" => unit_id, "x" => x, "y" => y})
  end

  @spec attack_requested(String.t(), String.t()) :: Event.t()
  def attack_requested(attacker_id, target_id) do
    Event.new("attack_requested", %{"attacker_id" => attacker_id, "target_id" => target_id})
  end

  @spec cover_requested(String.t()) :: Event.t()
  def cover_requested(unit_id) do
    Event.new("cover_requested", %{"unit_id" => unit_id})
  end

  @spec end_turn_requested(String.t()) :: Event.t()
  def end_turn_requested(unit_id) do
    Event.new("end_turn_requested", %{"unit_id" => unit_id})
  end

  @spec ap_spent(String.t(), non_neg_integer(), non_neg_integer()) :: Event.t()
  def ap_spent(unit_id, spent, remaining) do
    Event.new("ap_spent", %{
      "unit_id" => unit_id,
      "spent" => spent,
      "remaining_ap" => remaining
    })
  end

  @spec unit_moved(String.t(), integer(), integer()) :: Event.t()
  def unit_moved(unit_id, x, y) do
    Event.new("unit_moved", %{"unit_id" => unit_id, "x" => x, "y" => y})
  end

  @spec cover_applied(String.t()) :: Event.t()
  def cover_applied(unit_id) do
    Event.new("cover_applied", %{"unit_id" => unit_id})
  end

  @spec attack_resolved(
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          boolean(),
          non_neg_integer()
        ) ::
          Event.t()
  def attack_resolved(attacker_id, target_id, roll, chance, hit?, damage) do
    Event.new("attack_resolved", %{
      "attacker_id" => attacker_id,
      "target_id" => target_id,
      "roll" => roll,
      "chance" => chance,
      "hit" => hit?,
      "damage" => damage
    })
  end

  @spec damage_applied(String.t(), non_neg_integer(), non_neg_integer()) :: Event.t()
  def damage_applied(unit_id, damage, remaining_hp) do
    Event.new("damage_applied", %{
      "unit_id" => unit_id,
      "damage" => damage,
      "remaining_hp" => remaining_hp
    })
  end

  @spec unit_died(String.t(), String.t()) :: Event.t()
  def unit_died(unit_id, team) do
    Event.new("unit_died", %{"unit_id" => unit_id, "team" => team})
  end

  @spec turn_ended(String.t(), String.t()) :: Event.t()
  def turn_ended(unit_id, next_unit_id) do
    Event.new("turn_ended", %{"unit_id" => unit_id, "next_unit_id" => next_unit_id})
  end

  @spec round_advanced(pos_integer()) :: Event.t()
  def round_advanced(round) do
    Event.new("round_advanced", %{"round" => round})
  end

  @spec game_over(String.t()) :: Event.t()
  def game_over(winner) do
    Event.new("game_over", %{
      "status" => "won",
      "winner" => winner,
      "message" => "#{winner} wins the skirmish"
    })
  end

  @spec action_rejected(String.t(), String.t(), String.t()) :: Event.t()
  def action_rejected(kind, unit_id, reason) do
    Event.new("action_rejected", %{
      "kind" => kind,
      "unit_id" => unit_id,
      "reason" => reason
    })
  end
end
