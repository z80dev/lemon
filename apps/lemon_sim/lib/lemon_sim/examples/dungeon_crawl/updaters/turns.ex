defmodule LemonSim.Examples.DungeonCrawl.Updaters.Turns do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.DungeonCrawl.Updaters.Support

  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.State
  alias LemonSim.Examples.DungeonCrawl.Events
  alias LemonSim.Examples.DungeonCrawl.Updaters.Traps

  # -- End turn --

  def apply_end_turn(%State{} = state, event) do
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

  def continue_or_advance({:ok, %State{} = state, signal}, _actor_id) do
    # Already have a terminal signal (e.g., from room clear -> win)
    {:ok, state, signal}
  end

  def continue_or_advance(%State{} = state, actor_id) do
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

        next_state =
          State.update_world(state, fn _ -> next_world end)
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
    {trap_party, trap_events} = Traps.maybe_trigger_traps(world, updated_party)

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
          attack_events ++
            trap_events ++
            round_events ++
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
          attack_events ++
            trap_events ++
            round_events ++
            [Events.turn_ended("enemies", next_actor_id)]
        )

      {:ok, next_state, {:decide, "#{next_actor_id} turn (round #{next_round})"}}
    end
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
end
