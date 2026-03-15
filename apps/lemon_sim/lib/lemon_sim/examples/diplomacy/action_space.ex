defmodule LemonSim.Examples.Diplomacy.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Diplomacy.Events
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    phase = MapHelpers.get_key(world, :phase)
    actor_id = MapHelpers.get_key(world, :active_actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase == "diplomacy" ->
        {:ok, Enum.map(diplomacy_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "orders" ->
        {:ok, Enum.map(orders_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # -- Diplomacy phase tools --

  defp diplomacy_tools(world, actor_id) do
    messages_sent = count_messages_sent(world, actor_id)
    players = get(world, :players, %{})
    other_players = players |> Map.keys() |> Enum.reject(&(&1 == actor_id))

    tools = []

    tools =
      if messages_sent < 2 and length(other_players) > 0 do
        tools ++ [send_message_tool(actor_id, other_players)]
      else
        tools
      end

    tools ++ [end_diplomacy_tool(actor_id)]
  end

  defp send_message_tool(actor_id, other_players) do
    recipient_enum = Enum.map(other_players, &%{"const" => &1})

    %AgentTool{
      name: "send_message",
      description:
        "Send a private diplomatic message to another player. You have 2 messages per round. " <>
          "Use this to propose alliances, coordinate attacks, or deceive opponents. " <>
          "Available recipients: #{Enum.join(other_players, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "recipient" => %{
            "type" => "string",
            "description" => "The player_id of the recipient",
            "anyOf" => recipient_enum
          },
          "message" => %{
            "type" => "string",
            "description" =>
              "Your diplomatic message. Can contain proposals, threats, lies, or truth."
          }
        },
        "required" => ["recipient", "message"],
        "additionalProperties" => false
      },
      label: "Send Message",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        recipient = Map.get(params, "recipient", Map.get(params, :recipient))
        message = Map.get(params, "message", Map.get(params, :message, ""))
        event = Events.send_message(actor_id, recipient, message)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("sent message to #{recipient}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_diplomacy_tool(actor_id) do
    %AgentTool{
      name: "end_diplomacy",
      description:
        "End your diplomacy phase. You will move to orders once all players finish diplomacy.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Diplomacy",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_diplomacy(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending diplomacy phase for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Orders phase tools --

  defp orders_tools(world, actor_id) do
    territories = get(world, :territories, %{})
    adjacency = get(world, :adjacency, %{})

    owned_territories =
      territories
      |> Enum.filter(fn {_name, info} -> get(info, :owner, nil) == actor_id end)
      |> Enum.filter(fn {_name, info} -> get(info, :armies, 0) > 0 end)
      |> Enum.map(fn {name, _info} -> name end)

    pending = get(world, :pending_orders, %{})
    player_orders = Map.get(pending, actor_id, %{})
    already_ordered = Map.keys(player_orders)
    unordered = Enum.reject(owned_territories, &(&1 in already_ordered))

    tools = []

    tools =
      if length(unordered) > 0 do
        tools ++ [issue_order_tool(actor_id, unordered, adjacency)]
      else
        tools
      end

    tools ++ [submit_orders_tool(actor_id)]
  end

  defp issue_order_tool(actor_id, available_territories, adjacency) do
    territory_enum = Enum.map(available_territories, &%{"const" => &1})

    all_territories =
      adjacency
      |> Map.keys()
      |> Enum.map(&%{"const" => &1})

    %AgentTool{
      name: "issue_order",
      description:
        "Issue an order to one of your armies. Order types: " <>
          "'move' (move army to adjacent territory), " <>
          "'hold' (stay and defend current territory), " <>
          "'support' (support another army's move into a territory - specify support_target as the player whose move you support). " <>
          "Armies with orders: #{Enum.join(available_territories, ", ")}. " <>
          "Adjacency is enforced - you can only move to or support adjacent territories.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "army_territory" => %{
            "type" => "string",
            "description" => "Territory where your army is located",
            "anyOf" => territory_enum
          },
          "order_type" => %{
            "type" => "string",
            "enum" => ["move", "hold", "support"],
            "description" => "Type of order"
          },
          "target_territory" => %{
            "type" => "string",
            "description" =>
              "Target territory to move to, or territory to support. Same as army_territory for hold.",
            "anyOf" => all_territories
          },
          "support_target" => %{
            "type" => "string",
            "description" =>
              "For support orders only: the player_id whose move into the target territory you are supporting. Leave empty for move/hold."
          }
        },
        "required" => ["army_territory", "order_type", "target_territory"],
        "additionalProperties" => false
      },
      label: "Issue Order",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        army_territory = Map.get(params, "army_territory", Map.get(params, :army_territory))
        order_type = Map.get(params, "order_type", Map.get(params, :order_type))
        target_territory = Map.get(params, "target_territory", Map.get(params, :target_territory))
        support_target = Map.get(params, "support_target", Map.get(params, :support_target))

        event =
          Events.issue_order(actor_id, army_territory, order_type, target_territory, support_target)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "ordered army at #{army_territory} to #{order_type} -> #{target_territory}"
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp submit_orders_tool(actor_id) do
    %AgentTool{
      name: "submit_orders",
      description:
        "Submit all your orders for this round. Unordered armies will hold by default. " <>
          "Once all players submit, orders are resolved simultaneously.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Submit Orders",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.submit_orders(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("submitting orders for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Helpers --

  defp count_messages_sent(world, player_id) do
    round = get(world, :round, 1)
    messages_sent = get(world, :messages_sent_this_round, %{})
    Map.get(messages_sent, player_id, %{}) |> Map.get(round, 0)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
