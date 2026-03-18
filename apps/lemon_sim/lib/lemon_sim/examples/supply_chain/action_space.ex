defmodule LemonSim.Examples.SupplyChain.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.SupplyChain.Events
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @tier_order ["retailer", "distributor", "factory", "raw_materials"]

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    phase = MapHelpers.get_key(world, :phase)
    actor_id = MapHelpers.get_key(world, :active_actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase == "observe" ->
        {:ok, Enum.map(observe_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "communicate" ->
        {:ok, Enum.map(communicate_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "order" ->
        {:ok, Enum.map(order_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # -- Observe phase tools --

  defp observe_tools(_world, actor_id) do
    [check_inventory_tool(actor_id)]
  end

  defp check_inventory_tool(actor_id) do
    %AgentTool{
      name: "check_inventory",
      description:
        "Observe your current inventory, incoming orders, pending deliveries, backlog, and cash. " <>
          "You must call this to complete the observe phase and advance.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Check Inventory",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.check_inventory(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("observing inventory for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Communicate phase tools --

  defp communicate_tools(world, actor_id) do
    adjacent = adjacent_tiers(actor_id)
    existing_tiers = @tier_order

    tools =
      if length(adjacent) > 0 do
        [send_forecast_tool(actor_id, adjacent), request_info_tool(actor_id, adjacent, existing_tiers)]
      else
        []
      end

    tools ++ [end_communicate_tool(actor_id)]
  end

  defp send_forecast_tool(actor_id, adjacent_tiers) do
    tier_enum = Enum.map(adjacent_tiers, &%{"const" => &1})

    %AgentTool{
      name: "send_forecast",
      description:
        "Share a demand forecast with an adjacent tier partner (upstream or downstream). " <>
          "You can share expected order quantities, timing, or any information to help coordinate. " <>
          "Note: your partner cannot verify the information — you may be accurate or misleading. " <>
          "Adjacent partners: #{Enum.join(adjacent_tiers, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "recipient" => %{
            "type" => "string",
            "description" => "The tier_id to send the forecast to",
            "anyOf" => tier_enum
          },
          "forecast" => %{
            "type" => "object",
            "description" =>
              "Forecast data. Can include: expected_demand (integer), recommended_order (integer), notes (string). " <>
                "Include whatever information you think is useful.",
            "properties" => %{
              "expected_demand" => %{"type" => "integer", "description" => "Expected demand for next round"},
              "recommended_order" => %{"type" => "integer", "description" => "Suggested order quantity"},
              "notes" => %{"type" => "string", "description" => "Free-form message to your partner"}
            }
          }
        },
        "required" => ["recipient", "forecast"],
        "additionalProperties" => false
      },
      label: "Send Forecast",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        recipient = Map.get(params, "recipient", Map.get(params, :recipient))
        forecast = Map.get(params, "forecast", Map.get(params, :forecast, %{}))
        event = Events.send_forecast(actor_id, recipient, forecast)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("sent forecast to #{recipient}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp request_info_tool(actor_id, adjacent_tiers, _all_tiers) do
    tier_enum = Enum.map(adjacent_tiers, &%{"const" => &1})

    %AgentTool{
      name: "request_info",
      description:
        "Ask an adjacent tier partner for their inventory or demand information. " <>
          "They will see your request and may respond next round. " <>
          "Adjacent partners: #{Enum.join(adjacent_tiers, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target" => %{
            "type" => "string",
            "description" => "The tier_id to request information from",
            "anyOf" => tier_enum
          }
        },
        "required" => ["target"],
        "additionalProperties" => false
      },
      label: "Request Info",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target = Map.get(params, "target", Map.get(params, :target))
        event = Events.request_info(actor_id, target)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("requested info from #{target}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_communicate_tool(actor_id) do
    %AgentTool{
      name: "end_communicate",
      description:
        "End your communication phase. You move to the order phase once all tiers finish.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Communicate",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_communicate(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending communication phase for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Order phase tools --

  defp order_tools(world, actor_id) do
    tiers = get(world, :tiers, %{})
    tier = Map.get(tiers, actor_id, %{})
    safety_stock = get(tier, :safety_stock, 0)

    [place_order_tool(actor_id, safety_stock), adjust_safety_stock_tool(actor_id), expedite_order_tool(actor_id)]
    |> Enum.reject(&is_nil/1)
  end

  defp place_order_tool(actor_id, safety_stock) do
    is_rm = actor_id == "raw_materials"

    description =
      if is_rm do
        "Place your production order to extract raw materials. " <>
          "Your current safety stock target is #{safety_stock} units. " <>
          "You produce what you order — order enough to fulfill downstream demand."
      else
        upstream = upstream_tier(actor_id)

        "Place an order to your upstream supplier (#{upstream}). " <>
          "Your current safety stock target is #{safety_stock} units. " <>
          "Orders take 2 rounds to arrive. Consider your current inventory, backlog, and demand forecasts."
      end

    %AgentTool{
      name: "place_order",
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "quantity" => %{
            "type" => "integer",
            "description" => "Number of units to order (0 or more)",
            "minimum" => 0
          }
        },
        "required" => ["quantity"],
        "additionalProperties" => false
      },
      label: "Place Order",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        quantity = Map.get(params, "quantity", Map.get(params, :quantity, 0))
        event = Events.place_order(actor_id, quantity)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("placed order for #{quantity} units")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp adjust_safety_stock_tool(actor_id) do
    %AgentTool{
      name: "adjust_safety_stock",
      description:
        "Set your target minimum inventory level (safety stock). " <>
          "This is a reference target for your ordering strategy — the system does not enforce it automatically.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_minimum" => %{
            "type" => "integer",
            "description" => "Target minimum inventory level (0 or more)",
            "minimum" => 0
          }
        },
        "required" => ["target_minimum"],
        "additionalProperties" => false
      },
      label: "Adjust Safety Stock",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target = Map.get(params, "target_minimum", Map.get(params, :target_minimum, 0))
        event = Events.adjust_safety_stock(actor_id, target)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("adjusted safety stock to #{target} units")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp expedite_order_tool("raw_materials"), do: nil

  defp expedite_order_tool(actor_id) do
    upstream = upstream_tier(actor_id)

    %AgentTool{
      name: "expedite_order",
      description:
        "Pay a surcharge to receive an expedited delivery from #{upstream} in 1 round " <>
          "(instead of the normal 2-round delay). " <>
          "Expediting costs an additional 3.0 per unit on top of normal costs. " <>
          "Use only when stockout risk is critical.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "quantity" => %{
            "type" => "integer",
            "description" => "Number of units to expedite",
            "minimum" => 1
          }
        },
        "required" => ["quantity"],
        "additionalProperties" => false
      },
      label: "Expedite Order",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        quantity = Map.get(params, "quantity", Map.get(params, :quantity, 0))
        event = Events.expedite_order(actor_id, quantity)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("expediting #{quantity} units from #{upstream}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Tier adjacency --

  defp adjacent_tiers("retailer"), do: ["distributor"]
  defp adjacent_tiers("distributor"), do: ["retailer", "factory"]
  defp adjacent_tiers("factory"), do: ["distributor", "raw_materials"]
  defp adjacent_tiers("raw_materials"), do: ["factory"]
  defp adjacent_tiers(_), do: []

  defp upstream_tier("retailer"), do: "distributor"
  defp upstream_tier("distributor"), do: "factory"
  defp upstream_tier("factory"), do: "raw_materials"
  defp upstream_tier(_), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
