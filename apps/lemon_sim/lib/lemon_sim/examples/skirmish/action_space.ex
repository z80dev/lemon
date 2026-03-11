defmodule LemonSim.Examples.Skirmish.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Skirmish.{Events, UnitClasses}

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    phase = MapHelpers.get_key(world, :phase)
    actor_id = MapHelpers.get_key(world, :active_actor_id)
    actor = get_unit(world, actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase != "main" or is_nil(actor) ->
        {:ok, []}

      MapHelpers.get_key(actor, :status) == "dead" ->
        {:ok, []}

      true ->
        ap = get(actor, :ap, 0)
        has_sprint = UnitClasses.has_ability?(actor, :sprint)
        has_heal = UnitClasses.has_ability?(actor, :heal)

        action_tools =
          []
          |> maybe_add(ap > 0, move_tool(actor_id))
          |> maybe_add(ap > 0 and has_sprint, sprint_tool(actor_id))
          |> maybe_add(ap > 0, attack_tool(actor_id))
          |> maybe_add(ap > 0 and has_heal, heal_tool(actor_id))
          |> maybe_add(ap > 0, cover_tool(actor_id))
          |> maybe_add(true, end_turn_tool(actor_id))

        {:ok, action_tools}
    end
  end

  defp move_tool(actor_id) do
    %AgentTool{
      name: "move_unit",
      description: "Move #{actor_id} to an adjacent tile. Costs 1 AP (2 AP on water tiles). Cannot move onto walls.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "unit_id" => %{"type" => "string", "description" => "The acting unit id"},
          "x" => %{"type" => "integer", "description" => "Destination x coordinate"},
          "y" => %{"type" => "integer", "description" => "Destination y coordinate"}
        },
        "required" => ["unit_id", "x", "y"],
        "additionalProperties" => false
      },
      label: "Move Unit",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        unit_id = Map.get(params, "unit_id", actor_id)
        x = Map.get(params, "x", Map.get(params, :x))
        y = Map.get(params, "y", Map.get(params, :y))
        event = Events.move_requested(unit_id, x, y)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("proposed move for #{unit_id} to (#{x}, #{y})")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp sprint_tool(actor_id) do
    %AgentTool{
      name: "sprint",
      description: "Sprint #{actor_id} up to 2 tiles away for 1 AP. Scout ability. Clears cover.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "unit_id" => %{"type" => "string", "description" => "The acting unit id"},
          "x" => %{"type" => "integer", "description" => "Destination x coordinate"},
          "y" => %{"type" => "integer", "description" => "Destination y coordinate"}
        },
        "required" => ["unit_id", "x", "y"],
        "additionalProperties" => false
      },
      label: "Sprint",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        unit_id = Map.get(params, "unit_id", actor_id)
        x = Map.get(params, "x", Map.get(params, :x))
        y = Map.get(params, "y", Map.get(params, :y))
        event = Events.sprint_requested(unit_id, x, y)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("sprinting #{unit_id} to (#{x}, #{y})")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp attack_tool(actor_id) do
    %AgentTool{
      name: "attack_unit",
      description: "Attack a visible enemy with #{actor_id}.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "attacker_id" => %{"type" => "string", "description" => "The acting unit id"},
          "target_id" => %{"type" => "string", "description" => "The target unit id"}
        },
        "required" => ["attacker_id", "target_id"],
        "additionalProperties" => false
      },
      label: "Attack Unit",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        attacker_id = Map.get(params, "attacker_id", actor_id)
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.attack_requested(attacker_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("proposed attack from #{attacker_id} to #{target_id}")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp heal_tool(actor_id) do
    %AgentTool{
      name: "heal_unit",
      description: "Heal a wounded ally in range with #{actor_id}. Medic ability. Costs 1 AP.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "healer_id" => %{"type" => "string", "description" => "The acting medic unit id"},
          "target_id" => %{"type" => "string", "description" => "The ally unit id to heal"}
        },
        "required" => ["healer_id", "target_id"],
        "additionalProperties" => false
      },
      label: "Heal Unit",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        healer_id = Map.get(params, "healer_id", actor_id)
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.heal_requested(healer_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("healing #{target_id} with #{healer_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp cover_tool(actor_id) do
    %AgentTool{
      name: "take_cover",
      description: "Spend an action point to take cover with #{actor_id}. Reduces enemy hit chance by 20%.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "unit_id" => %{"type" => "string", "description" => "The acting unit id"}
        },
        "required" => ["unit_id"],
        "additionalProperties" => false
      },
      label: "Take Cover",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        unit_id = Map.get(params, "unit_id", actor_id)
        event = Events.cover_requested(unit_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("proposed cover action for #{unit_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_turn_tool(actor_id) do
    %AgentTool{
      name: "end_turn",
      description: "End #{actor_id}'s turn immediately.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "unit_id" => %{"type" => "string", "description" => "The acting unit id"}
        },
        "required" => ["unit_id"],
        "additionalProperties" => false
      },
      label: "End Turn",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        unit_id = Map.get(params, "unit_id", actor_id)
        event = Events.end_turn_requested(unit_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending turn for #{unit_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp maybe_add(list, true, tool), do: list ++ [tool]
  defp maybe_add(list, false, _tool), do: list

  defp get_unit(world, unit_id) when is_binary(unit_id) do
    world
    |> get(:units, %{})
    |> Map.get(unit_id)
  end

  defp get_unit(_world, _unit_id), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
