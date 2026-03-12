defmodule LemonSim.Examples.DungeonCrawl.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.DungeonCrawl.Events

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "attack_requested" -> apply_attack(state, event)
      "ability_requested" -> apply_ability(state, event)
      "use_item_requested" -> apply_use_item(state, event)
      "end_turn_requested" -> apply_end_turn(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Attack resolution --

  defp apply_attack(%State{} = state, event) do
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
      |> maybe_check_room_clear()
      |> continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  # -- Ability resolution --

  defp apply_ability(%State{} = state, event) do
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
      |> continue_or_advance(actor_id)
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
      living_enemies = Enum.filter(enemies, fn {_id, e} -> get(e, :status, "alive") == "alive" end)

      {updated_enemies, kill_events} =
        Enum.reduce(living_enemies, {enemies, []}, fn {enemy_id, enemy}, {acc_enemies, acc_events} ->
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
      |> maybe_check_room_clear()
      |> continue_or_advance(actor_id)
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
      |> maybe_check_room_clear()
      |> continue_or_advance(actor_id)
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
      |> continue_or_advance(actor_id)
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
      |> continue_or_advance(actor_id)
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
          |> continue_or_advance(actor_id)
      end
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  # -- Use item --

  defp apply_use_item(%State{} = state, event) do
    actor_id = fetch(event.payload, :actor_id, "actor_id")
    item_name = fetch(event.payload, :item, "item")
    params = fetch(event.payload, :params, "params") || %{}
    target_id = Map.get(params, "target_id", Map.get(params, :target_id, actor_id))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id),
         {:ok, actor} <- fetch_living_adventurer(state.world, actor_id),
         :ok <- ensure_ap(actor, 1),
         {:ok, item, remaining_inventory} <- find_and_remove_item(state.world, item_name) do
      updated_actor = Map.put(actor, :ap, get(actor, :ap, 0) - 1)

      {next_world, item_events} =
        case get(item, :effect, nil) do
          "heal" ->
            apply_healing_item(state.world, actor_id, target_id, updated_actor, item, remaining_inventory)

          "damage" ->
            apply_damage_item(state.world, actor_id, target_id, updated_actor, item, remaining_inventory)

          _ ->
            world =
              state.world
              |> put_adventurer(actor_id, updated_actor)
              |> Map.put(:inventory, remaining_inventory)

            {world, []}
        end

      base_events = [Events.ap_spent(actor_id, 1, get(updated_actor, :ap, 0))]

      state
      |> append_action(event, next_world, base_events ++ item_events)
      |> maybe_check_room_clear()
      |> continue_or_advance(actor_id)
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  defp apply_healing_item(world, actor_id, target_id, updated_actor, item, remaining_inventory) do
    party = get(world, :party, %{})
    target = Map.get(party, target_id)
    heal_value = get(item, :value, 5)

    if target && get(target, :hp, 0) > 0 do
      max_hp = get(target, :max_hp, get(target, :hp, 0))
      new_hp = min(get(target, :hp, 0) + heal_value, max_hp)
      actual_heal = new_hp - get(target, :hp, 0)
      updated_target = Map.put(target, :hp, new_hp)

      next_world =
        world
        |> put_adventurer(actor_id, updated_actor)
        |> put_adventurer(target_id, updated_target)
        |> Map.put(:inventory, remaining_inventory)

      events = [
        Events.item_used(actor_id, get(item, :name, "healing_potion"), %{"heal" => actual_heal, "target" => target_id}),
        Events.heal_applied(actor_id, target_id, actual_heal, new_hp)
      ]

      {next_world, events}
    else
      next_world =
        world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:inventory, remaining_inventory)

      {next_world, [Events.item_used(actor_id, get(item, :name, "healing_potion"), %{"wasted" => true})]}
    end
  end

  defp apply_damage_item(world, actor_id, target_id, updated_actor, item, remaining_inventory) do
    enemies = get(world, :enemies, %{})
    enemy = Map.get(enemies, target_id)
    damage_value = get(item, :value, 5)

    if enemy && get(enemy, :status, "alive") == "alive" do
      new_hp = max(get(enemy, :hp, 0) - damage_value, 0)

      updated_enemy =
        enemy
        |> Map.put(:hp, new_hp)
        |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

      next_world =
        world
        |> put_adventurer(actor_id, updated_actor)
        |> put_enemy(target_id, updated_enemy)
        |> Map.put(:inventory, remaining_inventory)

      events =
        [
          Events.item_used(actor_id, get(item, :name, "damage_scroll"), %{"damage" => damage_value, "target" => target_id}),
          Events.damage_applied(target_id, damage_value, new_hp)
        ] ++
          if(new_hp <= 0, do: [Events.enemy_killed(target_id)], else: [])

      {next_world, events}
    else
      next_world =
        world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:inventory, remaining_inventory)

      {next_world, [Events.item_used(actor_id, get(item, :name, "damage_scroll"), %{"wasted" => true})]}
    end
  end

  # -- End turn --

  defp apply_end_turn(%State{} = state, event) do
    actor_id = fetch(event.payload, :actor_id, "actor_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, actor_id) do
      state
      |> append_action(event, state.world, [])
      |> advance_turn()
    else
      {:error, reason} ->
        reject_action(state, event, actor_id, reason)
    end
  end

  # -- Turn management --

  defp continue_or_advance({:ok, %State{} = state, signal}, _actor_id) do
    # Already have a terminal signal (e.g., from room clear -> win)
    {:ok, state, signal}
  end

  defp continue_or_advance(%State{} = state, actor_id) do
    world = state.world

    if get(world, :status, "in_progress") != "in_progress" do
      {:ok, state, :skip}
    else
      party = get(world, :party, %{})
      actor = Map.get(party, actor_id)

      cond do
        is_nil(actor) ->
          advance_turn(state)

        get(actor, :hp, 0) <= 0 ->
          advance_turn(state)

        get(actor, :ap, 0) <= 0 ->
          advance_turn(state)

        true ->
          remaining = get(actor, :ap, 0)
          {:ok, state, {:decide, "#{actor_id} has #{remaining} AP remaining"}}
      end
    end
  end

  defp advance_turn(%State{} = state) do
    world = state.world
    turn_order = get(world, :turn_order, [])
    current_actor_id = MapHelpers.get_key(world, :active_actor_id)
    party = get(world, :party, %{})

    living_order =
      Enum.filter(turn_order, fn id ->
        adventurer = Map.get(party, id)
        adventurer && get(adventurer, :hp, 0) > 0
      end)

    case living_order do
      [] ->
        # All dead - should have been caught earlier
        next_world = Map.merge(world, %{status: "lost", winner: nil})
        next_state = State.update_world(state, fn _ -> next_world end)
        |> State.append_event(Events.game_over("lost", "The party has been wiped out"))
        {:ok, next_state, :skip}

      _ ->
        current_index = Enum.find_index(living_order, &(&1 == current_actor_id)) || 0
        next_index = rem(current_index + 1, length(living_order))
        next_actor_id = Enum.at(living_order, next_index)
        wrapped? = next_index == 0

        # If wrapped, that means all players have taken their turns -> enemy phase
        if wrapped? do
          run_enemy_phase(state, next_actor_id)
        else
          # Refresh next actor AP and set active
          next_world = refresh_actor_turn(world, next_actor_id)

          events = [Events.turn_ended(current_actor_id || next_actor_id, next_actor_id)]

          next_state =
            state
            |> State.update_world(fn _ -> next_world end)
            |> State.append_events(events)

          {:ok, next_state, {:decide, "#{next_actor_id} turn"}}
        end
    end
  end

  defp run_enemy_phase(%State{} = state, next_actor_id) do
    world = state.world
    enemies = get(world, :enemies, %{})
    party = get(world, :party, %{})
    taunt_target = get(world, :taunt_active, nil)

    living_enemies =
      enemies
      |> Enum.filter(fn {_id, e} -> get(e, :status, "alive") == "alive" end)
      |> Enum.sort_by(fn {id, _e} -> id end)

    {updated_party, attack_events} =
      Enum.reduce(living_enemies, {party, []}, fn {enemy_id, enemy}, {acc_party, acc_events} ->
        target_id = pick_enemy_target(acc_party, taunt_target)

        case target_id do
          nil ->
            {acc_party, acc_events}

          _ ->
            target = Map.get(acc_party, target_id)
            enemy_attack = get(enemy, :attack, 2)
            armor = get(target, :armor, 0)
            damage = max(enemy_attack - armor, 1)
            new_hp = max(get(target, :hp, 0) - damage, 0)

            updated_target =
              target
              |> Map.put(:hp, new_hp)
              |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

            events =
              [Events.enemy_attack_resolved(enemy_id, target_id, damage, new_hp)] ++
                if(new_hp <= 0, do: [Events.adventurer_downed(target_id)], else: [])

            {Map.put(acc_party, target_id, updated_target), acc_events ++ events}
        end
      end)

    # Trigger traps on party entry (only first round in a room)
    {trap_party, trap_events} = maybe_trigger_traps(world, updated_party)

    # Tick down buffs
    updated_buffs = tick_buffs(get(world, :buffs, %{}))

    # Check party wipe
    all_dead =
      Enum.all?(trap_party, fn {_id, a} -> get(a, :hp, 0) <= 0 end)

    next_round = get(world, :round, 1) + 1

    next_world =
      world
      |> Map.put(:party, trap_party)
      |> Map.put(:round, next_round)
      |> Map.put(:taunt_active, nil)
      |> Map.put(:attacks_this_turn, [])
      |> Map.put(:buffs, updated_buffs)

    round_events = [Events.round_advanced(next_round)]

    if all_dead do
      final_world = Map.merge(next_world, %{status: "lost", winner: nil, active_actor_id: nil})

      next_state =
        state
        |> State.update_world(fn _ -> final_world end)
        |> State.append_events(
          attack_events ++ trap_events ++ round_events ++
            [Events.game_over("lost", "The party has been wiped out")]
        )

      {:ok, next_state, :skip}
    else
      # Refresh next actor's AP
      final_world = refresh_actor_turn(next_world, next_actor_id)

      next_state =
        state
        |> State.update_world(fn _ -> final_world end)
        |> State.append_events(
          attack_events ++ trap_events ++ round_events ++
            [Events.turn_ended("enemies", next_actor_id)]
        )

      {:ok, next_state, {:decide, "#{next_actor_id} turn (round #{next_round})"}}
    end
  end

  # -- Room management --

  defp maybe_check_room_clear(%State{} = state) do
    world = state.world
    enemies = get(world, :enemies, %{})

    all_dead =
      Enum.all?(enemies, fn {_id, e} -> get(e, :status, "alive") != "alive" end)

    if all_dead do
      handle_room_clear(state)
    else
      state
    end
  end

  defp handle_room_clear(%State{} = state) do
    world = state.world
    current_room_index = get(world, :current_room, 0)
    rooms = get(world, :rooms, [])
    current_room = Enum.at(rooms, current_room_index, %{})

    # Mark room as cleared
    updated_room = Map.put(current_room, :cleared, true)
    updated_rooms = List.replace_at(rooms, current_room_index, updated_room)

    # Collect treasure
    treasure = get(current_room, :treasure, [])
    current_inventory = get(world, :inventory, [])
    new_inventory = current_inventory ++ treasure

    treasure_events =
      Enum.map(treasure, fn item ->
        Events.item_collected(get(item, :name, "unknown"))
      end)

    room_clear_events = [Events.room_cleared(current_room_index)] ++ treasure_events

    next_room_index = current_room_index + 1

    if next_room_index >= length(rooms) do
      # All rooms cleared - victory!
      next_world =
        world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:inventory, new_inventory)
        |> Map.put(:status, "won")
        |> Map.put(:winner, "party")
        |> Map.put(:active_actor_id, nil)

      victory_events =
        room_clear_events ++ [Events.game_over("won", "The dungeon has been cleared!")]

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_events(victory_events)

      {:ok, next_state, :skip}
    else
      # Move to next room
      next_room = Enum.at(rooms, next_room_index, %{})
      next_enemies = load_room_enemies(next_room)
      first_actor = find_first_living_actor(world)

      next_world =
        world
        |> Map.put(:rooms, updated_rooms)
        |> Map.put(:inventory, new_inventory)
        |> Map.put(:current_room, next_room_index)
        |> Map.put(:enemies, next_enemies)
        |> Map.put(:round, 1)
        |> Map.put(:taunt_active, nil)
        |> Map.put(:attacks_this_turn, [])

      next_world = refresh_all_ap(next_world)
      next_world = Map.put(next_world, :active_actor_id, first_actor)

      enter_events = room_clear_events ++ [Events.room_entered(next_room_index)]

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_events(enter_events)

      {:ok, next_state, {:decide, "Room #{next_room_index + 1}: #{get(next_room, :name, "Unknown")} - #{first_actor} turn"}}
    end
  end

  defp load_room_enemies(room) do
    room
    |> get(:enemies, [])
    |> Enum.into(%{}, fn enemy ->
      {get(enemy, :id, "unknown"), enemy}
    end)
  end

  defp find_first_living_actor(world) do
    turn_order = get(world, :turn_order, [])
    party = get(world, :party, %{})

    Enum.find(turn_order, List.first(turn_order), fn id ->
      adventurer = Map.get(party, id)
      adventurer && get(adventurer, :hp, 0) > 0
    end)
  end

  defp refresh_all_ap(world) do
    party = get(world, :party, %{})

    updated_party =
      Enum.into(party, %{}, fn {id, adventurer} ->
        if get(adventurer, :hp, 0) > 0 do
          {id, Map.put(adventurer, :ap, get(adventurer, :max_ap, 2))}
        else
          {id, adventurer}
        end
      end)

    Map.put(world, :party, updated_party)
  end

  defp refresh_actor_turn(world, actor_id) do
    party = get(world, :party, %{})
    actor = Map.get(party, actor_id, %{})
    max_ap = get(actor, :max_ap, 2)
    updated_actor = Map.put(actor, :ap, max_ap)

    world
    |> Map.put(:party, Map.put(party, actor_id, updated_actor))
    |> Map.put(:active_actor_id, actor_id)
  end

  # -- Trap handling --

  defp maybe_trigger_traps(world, party) do
    current_room_index = get(world, :current_room, 0)
    rooms = get(world, :rooms, [])
    current_room = Enum.at(rooms, current_room_index, %{})
    traps = get(current_room, :traps, [])
    round = get(world, :round, 1)

    # Only trigger traps on round 1 (when entering room)
    if round == 1 do
      Enum.reduce(traps, {party, []}, fn trap, {acc_party, acc_events} ->
        if get(trap, :disarmed, false) do
          {acc_party, acc_events}
        else
          trigger_trap(trap, acc_party, acc_events)
        end
      end)
    else
      {party, []}
    end
  end

  defp trigger_trap(trap, party, events) do
    trap_type = get(trap, :type, "unknown")
    damage = get(trap, :damage, 2)
    target_mode = get(trap, :target, "single")

    case target_mode do
      "all" ->
        # Hits all living party members
        Enum.reduce(party, {party, events}, fn {id, adventurer}, {acc_party, acc_events} ->
          if get(adventurer, :hp, 0) > 0 do
            new_hp = max(get(adventurer, :hp, 0) - damage, 0)

            updated =
              adventurer
              |> Map.put(:hp, new_hp)
              |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

            new_events =
              [Events.trap_triggered(trap_type, id, damage)] ++
                if(new_hp <= 0, do: [Events.adventurer_downed(id)], else: [])

            {Map.put(acc_party, id, updated), acc_events ++ new_events}
          else
            {acc_party, acc_events}
          end
        end)

      _ ->
        # Hits one random living party member
        living = Enum.filter(party, fn {_id, a} -> get(a, :hp, 0) > 0 end)

        case living do
          [] ->
            {party, events}

          _ ->
            {target_id, target} = Enum.random(living)
            new_hp = max(get(target, :hp, 0) - damage, 0)

            updated =
              target
              |> Map.put(:hp, new_hp)
              |> Map.put(:status, if(new_hp <= 0, do: "dead", else: "alive"))

            new_events =
              [Events.trap_triggered(trap_type, target_id, damage)] ++
                if(new_hp <= 0, do: [Events.adventurer_downed(target_id)], else: [])

            {Map.put(party, target_id, updated), events ++ new_events}
        end
    end
  end

  # -- Enemy targeting --

  defp pick_enemy_target(party, taunt_target) do
    living =
      Enum.filter(party, fn {_id, a} ->
        get(a, :hp, 0) > 0 and get(a, :status, "alive") == "alive"
      end)

    case living do
      [] ->
        nil

      _ ->
        # If taunt is active and the taunter is alive, target them
        if taunt_target do
          taunter = Enum.find(living, fn {id, _a} -> id == taunt_target end)

          if taunter do
            {id, _} = taunter
            id
          else
            pick_lowest_hp(living)
          end
        else
          pick_lowest_hp(living)
        end
    end
  end

  defp pick_lowest_hp(living) do
    {id, _} = Enum.min_by(living, fn {_id, a} -> get(a, :hp, 0) end)
    id
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

  defp tick_buffs(buffs) do
    Enum.into(buffs, %{}, fn {actor_id, actor_buffs} ->
      updated =
        actor_buffs
        |> Enum.map(fn buff ->
          Map.update(buff, :remaining_turns, 0, &(&1 - 1))
        end)
        |> Enum.filter(fn buff -> get(buff, :remaining_turns, 0) > 0 end)

      {actor_id, updated}
    end)
  end

  # -- Attack tracking --

  defp record_attack_this_turn(world, attacker_id, target_id) do
    attacks = get(world, :attacks_this_turn, [])
    new_attack = %{"attacker_id" => attacker_id, "target_id" => target_id}
    Map.put(world, :attacks_this_turn, attacks ++ [new_attack])
  end

  # -- Helpers --

  defp append_action(%State{} = state, event, next_world, action_events) do
    state
    |> State.append_event(event)
    |> State.update_world(fn _ -> next_world end)
    |> State.append_events(Enum.reject(action_events, &is_nil/1))
  end

  defp reject_action(%State{} = state, event, actor_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(to_string(event.kind), to_string(actor_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp ensure_in_progress(world) do
    if MapHelpers.get_key(world, :status) == "in_progress", do: :ok, else: {:error, :game_over}
  end

  defp ensure_active_actor(world, actor_id) do
    if MapHelpers.get_key(world, :active_actor_id) == actor_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp fetch_living_adventurer(world, actor_id) when is_binary(actor_id) do
    party = get(world, :party, %{})

    case Map.get(party, actor_id) do
      nil ->
        {:error, :unknown_adventurer}

      adventurer ->
        if get(adventurer, :hp, 0) <= 0 do
          {:error, :adventurer_dead}
        else
          {:ok, adventurer}
        end
    end
  end

  defp fetch_living_adventurer(_world, _actor_id), do: {:error, :invalid_actor}

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

  defp ensure_ap(actor, cost) do
    if get(actor, :ap, 0) >= cost, do: :ok, else: {:error, :insufficient_ap}
  end

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

  defp find_and_remove_item(world, item_name) do
    inventory = get(world, :inventory, [])

    case Enum.find_index(inventory, fn item -> get(item, :name, "") == item_name end) do
      nil ->
        {:error, :item_not_found}

      index ->
        item = Enum.at(inventory, index)
        remaining = List.delete_at(inventory, index)
        {:ok, item, remaining}
    end
  end

  defp put_adventurer(world, actor_id, adventurer) do
    party = get(world, :party, %{})
    Map.put(world, :party, Map.put(party, actor_id, adventurer))
  end

  defp put_enemy(world, enemy_id, enemy) do
    enemies = get(world, :enemies, %{})
    Map.put(world, :enemies, Map.put(enemies, enemy_id, enemy))
  end

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:not_active_actor), do: "not the active actor"
  defp rejection_reason(:unknown_adventurer), do: "unknown adventurer"
  defp rejection_reason(:invalid_actor), do: "invalid actor"
  defp rejection_reason(:adventurer_dead), do: "adventurer is dead"
  defp rejection_reason(:unknown_enemy), do: "unknown enemy"
  defp rejection_reason(:invalid_enemy), do: "invalid enemy"
  defp rejection_reason(:enemy_dead), do: "enemy is already dead"
  defp rejection_reason(:insufficient_ap), do: "insufficient AP"
  defp rejection_reason(:wrong_class), do: "wrong class for this ability"
  defp rejection_reason(:target_dead), do: "target is dead"
  defp rejection_reason(:target_full_hp), do: "target is at full health"
  defp rejection_reason(:item_not_found), do: "item not found in inventory"
  defp rejection_reason(:unknown_ability), do: "unknown ability"
  defp rejection_reason(:no_active_traps), do: "no active traps to disarm"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  defp fetch(map, atom_key, string_key) do
    Map.get(map, atom_key, Map.get(map, string_key))
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
