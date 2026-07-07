defmodule LemonSim.Examples.DungeonCrawl.Updaters.Combat do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.DungeonCrawl.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.DungeonCrawl.Events
  alias LemonSim.Examples.DungeonCrawl.Updaters.Rooms
  alias LemonSim.Examples.DungeonCrawl.Updaters.Turns

  # -- Attack resolution --

  def apply_attack(%State{} = state, event) do
    actor_id = fetch(event.payload, :actor_id, "actor_id")
    target_id = fetch(event.payload, :target_id, "target_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_ap(actor, 1),
         {:ok, enemy} <- fetch_living_enemy(state.world, target_id) do
      base_attack = get(actor, :attack, 0)
      bonus = get_bless_bonus(state.world, actor_id)
      raw_damage = base_attack + bonus
      armor = get(enemy, :armor, 0)
      damage = max(raw_damage - armor, 1)
      new_hp = max(get(enemy, :hp, 0) - damage, 0)

      updated_enemy =
        enemy
        |> Map.put(:hp, new_hp)
        |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)

      next_world =
        state.world
        |> put_adventurer(actor_id, updated_actor)
        |> put_enemy(target_id, updated_enemy)
        |> record_attack_this_turn(actor_id, target_id)

      action_events =
        [
          Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0)),
          Events.attack_resolved(actor_id, target_id, damage, new_hp)
        ] ++
          if(new_hp <= 0, do: [Events.enemy_killed(target_id)], else: [])

      state
      |> append_action(event, next_world, action_events)
      |> Rooms.maybe_check_room_clear()
      |> Turns.continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  # -- Ability resolution --

  def apply_ability(%State{} = state, event) do
    actor_id = fetch(event.payload, :actor_id, "actor_id")
    ability = fetch(event.payload, :ability, "ability")
    params = fetch(event.payload, :params, "params") || %{}

    case ability do
      "taunt" -> apply_taunt(state, event, actor_id)
      "fireball" -> apply_fireball(state, event, actor_id)
      "backstab" -> apply_backstab(state, event, actor_id, params)
      "heal" -> apply_heal(state, event, actor_id, params)
      "bless" -> apply_bless(state, event, actor_id, params)
      "disarm_trap" -> apply_disarm_trap(state, event, actor_id)
      _ -> reject_action(state, event, actor_id, :unknown_ability)
    end
  end

  defp apply_taunt(%State{} = state, event, actor_id) do
    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_class(actor, "warrior"),
         :ok <- ensure_ap(actor, 1) do
      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)

      next_world =
        state.world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:taunt_active, actor_id)

      action_events = [
        Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0)),
        Events.taunt_applied(actor_id)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> Turns.continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  defp apply_fireball(%State{} = state, event, actor_id) do
    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_class(actor, "mage"),
         :ok <- ensure_ap(actor, 2) do
      enemies = get(state.world, :enemies, %{})

      living_enemies =
        Enum.filter(enemies, fn {_id, e} -> get(e, :status, "alive") == "alive" end)

      {updated_enemies, kill_events} =
        Enum.reduce(living_enemies, {enemies, []}, fn {enemy_id, enemy},
                                                      {acc_enemies, acc_events} ->
          new_hp = max(get(enemy, :hp, 0) - 2, 0)

          updated_enemy =
            enemy
            |> Map.put(:hp, new_hp)
            |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

          events =
            [Events.damage_applied(enemy_id, 2, new_hp)] ++
              if(new_hp <= 0, do: [Events.enemy_killed(enemy_id)], else: [])

          {Map.put(acc_enemies, enemy_id, updated_enemy), acc_events ++ events}
        end)

      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 2)

      next_world =
        state.world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:enemies, updated_enemies)

      action_events =
        [
          Events.ap_spent(actor_id, 2, get(updated_actor, :ap, 0)),
          Events.fireball_resolved(actor_id, length(living_enemies))
        ] ++ kill_events

      state
      |> append_action(event, next_world, action_events)
      |> Rooms.maybe_check_room_clear()
      |> Turns.continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  defp apply_backstab(%State{} = state, event, actor_id, params) do
    target_id = Map.get(params, "target_id", Map.get(params, :target_id))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_class(actor, "rogue"),
         :ok <- ensure_ap(actor, 1),
         {:ok, enemy} <- fetch_living_enemy(state.world, target_id) do
      base_attack = get(actor, :attack, 0)
      bonus = get_bless_bonus(state.world, actor_id)
      raw_damage = base_attack + bonus

      # Check if any ally attacked this target this turn
      attacks_this_turn = get(state.world, :attacks_this_turn, [])

      ally_attacked_same =
        Enum.any?(attacks_this_turn, fn atk ->
          Map.get(atk, "target_id") == target_id and Map.get(atk, "attacker_id") != actor_id
        end)

      damage = if ally_attacked_same, do: raw_damage * 2, else: raw_damage
      armor = get(enemy, :armor, 0)
      final_damage = max(damage - armor, 1)
      new_hp = max(get(enemy, :hp, 0) - final_damage, 0)

      updated_enemy =
        enemy
        |> Map.put(:hp, new_hp)
        |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)

      next_world =
        state.world
        |> put_adventurer(actor_id, updated_actor)
        |> put_enemy(target_id, updated_enemy)
        |> record_attack_this_turn(actor_id, target_id)

      action_events =
        [
          Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0)),
          Events.backstab_resolved(actor_id, target_id, final_damage, new_hp)
        ] ++
          if(new_hp <= 0, do: [Events.enemy_killed(target_id)], else: [])

      state
      |> append_action(event, next_world, action_events)
      |> Rooms.maybe_check_room_clear()
      |> Turns.continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  defp apply_heal(%State{} = state, event, actor_id, params) do
    target_id = Map.get(params, "target_id", Map.get(params, :target_id))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_class(actor, "cleric"),
         :ok <- ensure_ap(actor, 1),
         {:ok, target} <- fetch_adventurer(state.world, target_id),
         :ok <- ensure_alive(target),
         :ok <- ensure_wounded(target) do
      heal_amount = get(actor, :heal, 4)
      max_hp = get(target, :max_hp, get(target, :hp, 0))
      new_hp = min(get(target, :hp, 0) + heal_amount, max_hp)
      actual_heal = new_hp - get(target, :hp, 0)

      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)
      updated_target = Map.put(target, :hp, new_hp)

      next_world =
        state.world
        |> put_adventurer(actor_id, updated_actor)
        |> put_adventurer(target_id, updated_target)

      action_events = [
        Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0)),
        Events.heal_applied(actor_id, target_id, actual_heal, new_hp)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> Turns.continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  defp apply_bless(%State{} = state, event, actor_id, params) do
    target_id = Map.get(params, "target_id", Map.get(params, :target_id))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_class(actor, "cleric"),
         :ok <- ensure_ap(actor, 1),
         {:ok, target} <- fetch_adventurer(state.world, target_id),
         :ok <- ensure_alive(target) do
      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)

      buffs = get(state.world, :buffs, %{})
      target_buffs = Map.get(buffs, target_id, [])
      new_buff = %{type: "bless", attack_bonus: 1, remaining_turns: 2}
      updated_buffs = Map.put(buffs, target_id, target_buffs ++ [new_buff])

      next_world =
        state.world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:buffs, updated_buffs)

      action_events = [
        Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0)),
        Events.buff_applied(actor_id, target_id, "bless", 2)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> Turns.continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  defp apply_disarm_trap(%State{} = state, event, actor_id) do
    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_class(actor, "rogue"),
         :ok <- ensure_ap(actor, 1) do
      current_room_index = get(state.world, :current_room, 0)
      rooms = get(state.world, :rooms, [])
      current_room = Enum.at(rooms, current_room_index, %{})
      traps = get(current_room, :traps, [])

      active_trap = Enum.find(traps, fn t -> get(t, :disarmed, false) == false end)

      case active_trap do
        nil ->
          reject_action(state, event, actor_id, :no_active_traps)

        trap ->
          updated_traps =
            Enum.map(traps, fn t ->
              if t == trap, do: Map.put(t, :disarmed, true), else: t
            end)

          updated_room = Map.put(current_room, :traps, updated_traps)
          updated_rooms = List.replace_at(rooms, current_room_index, updated_room)
          updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)

          next_world =
            state.world
            |> put_adventurer(actor_id, updated_actor)
            |> Map.put(:rooms, updated_rooms)

          trap_type = get(trap, :type, "unknown")

          action_events = [
            Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0)),
            Events.trap_disarmed(actor_id, trap_type)
          ]

          state
          |> append_action(event, next_world, action_events)
          |> Turns.continue_or_advance(actor_id)
      end
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  # -- Local validation helpers --

  defp fetch_adventurer(world, actor_id) when is_binary(actor_id) do
    party = get(world, :party, %{})

    case Map.get(party, actor_id) do
      nil -> {:error, :unknown_adventurer}
      adventurer -> {:ok, adventurer}
    end
  end

  defp fetch_adventurer(_world, _actor_id), do: {:error, :invalid_actor}

  defp fetch_living_enemy(world, enemy_id) when is_binary(enemy_id) do
    enemies = get(world, :enemies, %{})

    case Map.get(enemies, enemy_id) do
      nil ->
        {:error, :unknown_enemy}

      enemy ->
        if get(enemy, :status, "alive") != "alive" or get(enemy, :hp, 0) <= 0 do
          {:error, :enemy_dead}
        else
          {:ok, enemy}
        end
    end
  end

  defp fetch_living_enemy(_world, _enemy_id), do: {:error, :invalid_enemy}

  defp ensure_class(actor, expected_class) do
    if get(actor, :class, "") == expected_class, do: :ok, else: {:error, :wrong_class}
  end

  defp ensure_alive(target) do
    if get(target, :hp, 0) > 0, do: :ok, else: {:error, :target_dead}
  end

  defp ensure_wounded(target) do
    hp = get(target, :hp, 0)
    max_hp = get(target, :max_hp, hp)
    if hp < max_hp, do: :ok, else: {:error, :target_full_hp}
  end

  # -- Buff management --

  defp get_bless_bonus(world, actor_id) do
    buffs = get(world, :buffs, %{})
    actor_buffs = Map.get(buffs, actor_id, [])

    Enum.reduce(actor_buffs, 0, fn buff, acc ->
      if get(buff, :type, nil) == "bless" do
        acc + get(buff, :attack_bonus, 0)
      else
        acc
      end
    end)
  end

  # -- Attack tracking --

  defp record_attack_this_turn(world, attacker_id, target_id) do
    attacks = get(world, :attacks_this_turn, [])
    new_attack = %{"attacker_id" => attacker_id, "target_id" => target_id}
    Map.put(world, :attacks_this_turn, attacks ++ [new_attack])
  end
end
