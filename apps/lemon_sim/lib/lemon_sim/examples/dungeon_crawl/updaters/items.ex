defmodule LemonSim.Examples.DungeonCrawl.Updaters.Items do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.DungeonCrawl.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.DungeonCrawl.Events
  alias LemonSim.Examples.DungeonCrawl.Updaters.Rooms
  alias LemonSim.Examples.DungeonCrawl.Updaters.Turns

  # -- Use item --

  def apply_use_item(%State{} = state, event) do
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
            apply_healing_item(
              state.world,
              actor_id,
              target_id,
              updated_actor,
              item,
              remaining_inventory
            )

          "damage" ->
            apply_damage_item(
              state.world,
              actor_id,
              target_id,
              updated_actor,
              item,
              remaining_inventory
            )

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
      |> Rooms.maybe_check_room_clear()
      |> Turns.continue_or_advance(actor_id)
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
        Events.item_used(actor_id, get(item, :name, "healing_potion"), %{
          "heal" => actual_heal,
          "target" => target_id
        }),
        Events.heal_applied(actor_id, target_id, actual_heal, new_hp)
      ]

      {next_world, events}
    else
      next_world =
        world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:inventory, remaining_inventory)

      {next_world,
       [Events.item_used(actor_id, get(item, :name, "healing_potion"), %{"wasted" => true})]}
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
          Events.item_used(actor_id, get(item, :name, "damage_scroll"), %{
            "damage" => damage_value,
            "target" => target_id
          }),
          Events.damage_applied(target_id, damage_value, new_hp)
        ] ++
          if(new_hp <= 0, do: [Events.enemy_killed(target_id)], else: [])

      {next_world, events}
    else
      next_world =
        world
        |> put_adventurer(actor_id, updated_actor)
        |> Map.put(:inventory, remaining_inventory)

      {next_world,
       [Events.item_used(actor_id, get(item, :name, "damage_scroll"), %{"wasted" => true})]}
    end
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
end
