defmodule LemonSim.Examples.Auction.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.GameHelpers.Tools, as: GameTools
  alias LemonSim.Examples.Auction.Events

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = get(world, :status, "in_progress")
    phase = get(world, :phase, "bidding")
    actor_id = MapHelpers.get_key(world, :active_actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase != "bidding" ->
        {:ok, []}

      is_nil(actor_id) ->
        {:ok, []}

      true ->
        active_bidders = get(world, :active_bidders, [])

        if actor_id in active_bidders do
          high_bid = get(world, :high_bid, 0)
          player = get_player(world, actor_id)
          gold = get(player, :gold, 0)
          min_bid = high_bid + 2
          current_item = get(world, :current_item, %{})
          item_name = get(current_item, :name, "Unknown")

          tools =
            []
            |> maybe_add(gold >= min_bid, place_bid_tool(actor_id, high_bid, min_bid, item_name))
            |> maybe_add(true, pass_auction_tool(actor_id))

          {:ok, Enum.map(tools, &GameTools.add_thought_param/1)}
        else
          {:ok, []}
        end
    end
  end

  defp place_bid_tool(actor_id, high_bid, min_bid, item_name) do
    %AgentTool{
      name: "place_bid",
      description:
        "Place a bid on #{item_name}. Current high bid: #{high_bid} gold. Minimum bid: #{min_bid} gold. You must bid at least #{min_bid}.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "amount" => %{
            "type" => "integer",
            "description" =>
              "The bid amount in gold. Must be at least #{min_bid} (current high bid #{high_bid} + minimum increment of 2)."
          }
        },
        "required" => ["amount"],
        "additionalProperties" => false
      },
      label: "Place Bid",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        amount = Map.get(params, "amount", Map.get(params, :amount))
        event = Events.place_bid(actor_id, amount)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} bids #{amount} gold on #{item_name}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp pass_auction_tool(actor_id) do
    %AgentTool{
      name: "pass_auction",
      description:
        "Pass on the current item. You will be removed from bidding on this item and cannot bid on it again.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Pass",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.pass_auction(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} passes on this item")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp maybe_add(list, true, tool), do: list ++ [tool]
  defp maybe_add(list, false, _tool), do: list

  defp get_player(world, player_id) do
    world
    |> get(:players, %{})
    |> Map.get(player_id)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
