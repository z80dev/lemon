defmodule LemonSim.Examples.DungeonCrawl.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.DungeonCrawl.Events
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    actor_id = MapHelpers.get_key(world, :active_actor_id)
    party = get(world, :party, %{})
    actor = Map.get(party, actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      is_nil(actor) ->
        {:ok, []}

      get(actor, :hp, 0) <= 0 ->
        {:ok, []}

      true ->
        ap = get(actor, :ap, 0)
        class = get(actor, :class, "warrior")
        enemies = get(world, :enemies, %{})
        has_living_enemies = Enum.any?(enemies, fn {_id, e} -> get(e, :status, "alive") == "alive" end)
        inventory = get(world, :inventory, [])
        has_items = length(inventory) > 0
        current_room_index = get(world, :current_room, 0)
        rooms = get(world, :rooms, [])
        current_room = Enum.at(rooms, current_room_index, %{})
        traps = get(current_room, :traps, [])
        has_active_traps = Enum.any?(traps, fn t -> get(t, :disarmed, false) == false end)

        action_tools =
          []
          |> maybe_add(ap > 0 and has_living_enemies, attack_tool(actor_id))
          |> maybe_add_abilities(actor_id, class, ap, has_living_enemies, has_active_traps, party)
          |> maybe_add(ap > 0 and has_items, use_item_tool(actor_id, inventory, enemies))
          |> maybe_add(true, end_turn_tool(actor_id))

        {:ok, Enum.map(action_tools, &GameTools.add_thought_param/1)}
    end
  end

  defp maybe_add_abilities(tools, actor_id, class, ap, has_living_enemies, has_active_traps, party) do
    case class do
      "warrior" ->
        tools
        |> maybe_add(ap > 0 and has_living_enemies, taunt_tool(actor_id))

      "mage" ->
        tools
        |> maybe_add(ap >= 2 and has_living_enemies, fireball_tool(actor_id))

      "rogue" ->
        tools
        |> maybe_add(ap > 0 and has_living_enemies, backstab_tool(actor_id))
        |> maybe_add(ap > 0 and has_active_traps, disarm_trap_tool(actor_id))

      "cleric" ->
        has_wounded = Enum.any?(party, fn {_id, a} ->
          get(a, :hp, 0) > 0 and get(a, :hp, 0) < get(a, :max_hp, 0)
        end)

        tools
        |> maybe_add(ap > 0 and has_wounded, heal_tool(actor_id))
        |> maybe_add(ap > 0, bless_tool(actor_id))

      _ ->
        tools
    end
  end

  defp attack_tool(actor_id) do
    %AgentTool{
      name: "attack_enemy",
      description: "Attack an enemy with #{actor_id}. Costs 1 AP.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The enemy id to attack (e.g. goblin_0_1)"
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Attack Enemy",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.attack_requested(actor_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} attacks #{target_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp taunt_tool(actor_id) do
    %AgentTool{
      name: "use_taunt",
      description: "Force all enemies to attack #{actor_id} next enemy phase. Costs 1 AP. Warrior ability.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Taunt",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.ability_requested(actor_id, "taunt")

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} taunts the enemies")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp fireball_tool(actor_id) do
    %AgentTool{
      name: "use_fireball",
      description: "Hit ALL enemies in the room for 2 damage. Costs 2 AP. Mage ability.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Fireball",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.ability_requested(actor_id, "fireball")

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} casts fireball")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp backstab_tool(actor_id) do
    %AgentTool{
      name: "use_backstab",
      description:
        "Backstab an enemy for double damage if an ally attacked the same target this turn. Otherwise deals normal damage. Costs 1 AP. Rogue ability.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The enemy id to backstab"
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Backstab",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.ability_requested(actor_id, "backstab", %{"target_id" => target_id})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} backstabs #{target_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp disarm_trap_tool(actor_id) do
    %AgentTool{
      name: "disarm_trap",
      description: "Disarm an active trap in the current room. Costs 1 AP. Rogue ability.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Disarm Trap",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.ability_requested(actor_id, "disarm_trap")

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} disarms a trap")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp heal_tool(actor_id) do
    %AgentTool{
      name: "use_heal",
      description: "Heal an ally for 4 HP. Costs 1 AP. Cleric ability.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The ally id to heal (e.g. warrior, rogue, mage, cleric)"
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Heal",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.ability_requested(actor_id, "heal", %{"target_id" => target_id})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} heals #{target_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp bless_tool(actor_id) do
    %AgentTool{
      name: "use_bless",
      description: "Give an ally +1 attack for 2 turns. Costs 1 AP. Cleric ability.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The ally id to bless (e.g. warrior, rogue, mage, cleric)"
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Bless",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.ability_requested(actor_id, "bless", %{"target_id" => target_id})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} blesses #{target_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp use_item_tool(actor_id, inventory, enemies) do
    item_names = Enum.map(inventory, fn item -> get(item, :name, "unknown") end) |> Enum.uniq()
    enemy_ids = enemies |> Enum.filter(fn {_id, e} -> get(e, :status, "alive") == "alive" end) |> Enum.map(fn {id, _e} -> id end)

    item_desc = Enum.join(item_names, ", ")
    target_desc = if length(enemy_ids) > 0, do: " Target enemies: #{Enum.join(enemy_ids, ", ")}.", else: ""

    %AgentTool{
      name: "use_item",
      description: "Use an item from party inventory. Available: #{item_desc}.#{target_desc} Costs 1 AP.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "item_name" => %{
            "type" => "string",
            "description" => "Name of item to use (healing_potion or damage_scroll)"
          },
          "target_id" => %{
            "type" => "string",
            "description" => "Target id (ally id for potions, enemy id for damage scrolls). Optional for healing potions (defaults to self)."
          }
        },
        "required" => ["item_name"],
        "additionalProperties" => false
      },
      label: "Use Item",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        item_name = Map.get(params, "item_name", Map.get(params, :item_name))
        target_id = Map.get(params, "target_id", Map.get(params, :target_id, actor_id))
        event = Events.use_item_requested(actor_id, item_name, %{"target_id" => target_id})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} uses #{item_name} on #{target_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_turn_tool(actor_id) do
    %AgentTool{
      name: "end_turn",
      description: "End #{actor_id}'s turn, passing any remaining AP.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Turn",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_turn_requested(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending turn for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp maybe_add(list, true, tool), do: list ++ [tool]
  defp maybe_add(list, false, _tool), do: list

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
