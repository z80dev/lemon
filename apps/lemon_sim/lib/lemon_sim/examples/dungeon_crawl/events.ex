defmodule LemonSim.Examples.DungeonCrawl.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  # -- Player action requests --

  @spec attack_requested(String.t(), String.t()) :: Event.t()
  def attack_requested(actor_id, target_id) do
    Event.new("attack_requested", %{"actor_id" => actor_id, "target_id" => target_id})
  end

  @spec ability_requested(String.t(), String.t(), map()) :: Event.t()
  def ability_requested(actor_id, ability_name, params \\ %{}) do
    Event.new("ability_requested", %{
      "actor_id" => actor_id,
      "ability" => ability_name,
      "params" => params
    })
  end

  @spec use_item_requested(String.t(), String.t(), map()) :: Event.t()
  def use_item_requested(actor_id, item_name, params \\ %{}) do
    Event.new("use_item_requested", %{
      "actor_id" => actor_id,
      "item" => item_name,
      "params" => params
    })
  end

  @spec end_turn_requested(String.t()) :: Event.t()
  def end_turn_requested(actor_id) do
    Event.new("end_turn_requested", %{"actor_id" => actor_id})
  end

  # -- Resolution events --

  @spec attack_resolved(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: Event.t()
  def attack_resolved(attacker_id, target_id, damage, remaining_hp) do
    Event.new("attack_resolved", %{
      "attacker_id" => attacker_id,
      "target_id" => target_id,
      "damage" => damage,
      "remaining_hp" => remaining_hp
    })
  end

  @spec damage_applied(String.t(), non_neg_integer(), non_neg_integer()) :: Event.t()
  def damage_applied(target_id, damage, remaining_hp) do
    Event.new("damage_applied", %{
      "target_id" => target_id,
      "damage" => damage,
      "remaining_hp" => remaining_hp
    })
  end

  @spec enemy_killed(String.t()) :: Event.t()
  def enemy_killed(enemy_id) do
    Event.new("enemy_killed", %{"enemy_id" => enemy_id})
  end

  @spec adventurer_downed(String.t()) :: Event.t()
  def adventurer_downed(actor_id) do
    Event.new("adventurer_downed", %{"actor_id" => actor_id})
  end

  @spec heal_applied(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: Event.t()
  def heal_applied(healer_id, target_id, amount, new_hp) do
    Event.new("heal_applied", %{
      "healer_id" => healer_id,
      "target_id" => target_id,
      "amount" => amount,
      "new_hp" => new_hp
    })
  end

  @spec buff_applied(String.t(), String.t(), String.t(), non_neg_integer()) :: Event.t()
  def buff_applied(caster_id, target_id, buff_name, duration) do
    Event.new("buff_applied", %{
      "caster_id" => caster_id,
      "target_id" => target_id,
      "buff" => buff_name,
      "duration" => duration
    })
  end

  @spec taunt_applied(String.t()) :: Event.t()
  def taunt_applied(actor_id) do
    Event.new("taunt_applied", %{"actor_id" => actor_id})
  end

  @spec fireball_resolved(String.t(), non_neg_integer()) :: Event.t()
  def fireball_resolved(caster_id, enemies_hit) do
    Event.new("fireball_resolved", %{
      "caster_id" => caster_id,
      "enemies_hit" => enemies_hit
    })
  end

  @spec backstab_resolved(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          Event.t()
  def backstab_resolved(attacker_id, target_id, damage, remaining_hp) do
    Event.new("backstab_resolved", %{
      "attacker_id" => attacker_id,
      "target_id" => target_id,
      "damage" => damage,
      "remaining_hp" => remaining_hp
    })
  end

  @spec trap_triggered(String.t(), String.t(), non_neg_integer()) :: Event.t()
  def trap_triggered(trap_type, target_id, damage) do
    Event.new("trap_triggered", %{
      "trap_type" => trap_type,
      "target_id" => target_id,
      "damage" => damage
    })
  end

  @spec trap_disarmed(String.t(), String.t()) :: Event.t()
  def trap_disarmed(actor_id, trap_type) do
    Event.new("trap_disarmed", %{"actor_id" => actor_id, "trap_type" => trap_type})
  end

  @spec item_used(String.t(), String.t(), map()) :: Event.t()
  def item_used(actor_id, item_name, effect) do
    Event.new("item_used", %{
      "actor_id" => actor_id,
      "item" => item_name,
      "effect" => effect
    })
  end

  @spec item_collected(String.t()) :: Event.t()
  def item_collected(item_name) do
    Event.new("item_collected", %{"item" => item_name})
  end

  @spec enemy_attack_resolved(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          Event.t()
  def enemy_attack_resolved(enemy_id, target_id, damage, remaining_hp) do
    Event.new("enemy_attack_resolved", %{
      "enemy_id" => enemy_id,
      "target_id" => target_id,
      "damage" => damage,
      "remaining_hp" => remaining_hp
    })
  end

  @spec ap_spent(String.t(), non_neg_integer(), non_neg_integer()) :: Event.t()
  def ap_spent(actor_id, spent, remaining) do
    Event.new("ap_spent", %{
      "actor_id" => actor_id,
      "spent" => spent,
      "remaining_ap" => remaining
    })
  end

  @spec turn_ended(String.t(), String.t()) :: Event.t()
  def turn_ended(actor_id, next_actor_id) do
    Event.new("turn_ended", %{"actor_id" => actor_id, "next_actor_id" => next_actor_id})
  end

  @spec round_advanced(pos_integer()) :: Event.t()
  def round_advanced(round) do
    Event.new("round_advanced", %{"round" => round})
  end

  @spec room_entered(non_neg_integer()) :: Event.t()
  def room_entered(room_index) do
    Event.new("room_entered", %{"room_index" => room_index})
  end

  @spec room_cleared(non_neg_integer()) :: Event.t()
  def room_cleared(room_index) do
    Event.new("room_cleared", %{"room_index" => room_index})
  end

  @spec enemy_phase_resolved(list()) :: Event.t()
  def enemy_phase_resolved(attacks) do
    Event.new("enemy_phase_resolved", %{"attacks" => attacks})
  end

  @spec game_over(String.t(), String.t()) :: Event.t()
  def game_over(status, message) do
    Event.new("game_over", %{
      "status" => status,
      "message" => message
    })
  end

  @spec action_rejected(String.t(), String.t(), String.t()) :: Event.t()
  def action_rejected(kind, actor_id, reason) do
    Event.new("action_rejected", %{
      "kind" => kind,
      "actor_id" => actor_id,
      "reason" => reason
    })
  end
end
