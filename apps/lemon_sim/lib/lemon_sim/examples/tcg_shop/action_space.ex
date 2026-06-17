defmodule LemonSim.Examples.TcgShop.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.Kernel.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Helpers.Tools, as: GameTools
  alias LemonSim.Examples.TcgShop.{Catalog, Events}
  alias LemonSim.LLM.Memory.Tools, as: MemoryTools

  @impl true
  def tools(state, _opts) do
    world = state.world

    if MapHelpers.get_key(world, :status) == "in_progress" do
      tools =
        support_tools(world) ++
          MemoryTools.build(sim_id: "#{state.sim_id}/operator") ++
          terminal_tools(world)

      {:ok, Enum.map(tools, &GameTools.add_thought_param/1)}
    else
      {:ok, []}
    end
  end

  defp support_tools(world) do
    [
      check_dashboard_tool(world),
      inspect_inventory_tool(world),
      research_market_tool(),
      review_customers_tool(world)
    ]
  end

  defp terminal_tools(_world) do
    [
      order_product_line_tool(),
      buy_collection_tool(),
      set_prices_tool(),
      host_event_tool(),
      submit_grading_tool(),
      process_online_orders_tool(),
      wait_next_day_tool()
    ]
  end

  defp check_dashboard_tool(world) do
    %AgentTool{
      name: "tcg_check_dashboard",
      description:
        "Check cash, net worth, reputation, current day, pending deliveries, and grading.",
      parameters: empty_params(),
      label: "Check Dashboard",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        day = get(world, :day_number, 1)
        balance = get(world, :bank_balance, 0.0)

        text = """
        Day #{day}/#{get(world, :max_days, 14)}
        Bank balance: $#{money(balance)}
        Reputation: #{get(world, :reputation, 50)}/100
        Online rating: #{get(world, :online_rating, 4.3)}
        Pending deliveries: #{length(get(world, :pending_deliveries, []))}
        Pending grading: #{length(get(world, :pending_grading, []))}
        """

        tool_result(text, Events.checked_dashboard(day, balance))
      end
    }
  end

  defp inspect_inventory_tool(world) do
    %AgentTool{
      name: "tcg_inspect_inventory",
      description:
        "Inspect sealed product, accessories, singles case value, and current shelf prices.",
      parameters: empty_params(),
      label: "Inspect Inventory",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        inventory = get(world, :inventory, %{})
        catalog = get(world, :catalog, %{})
        singles = get(world, :singles_case, %{})

        lines =
          inventory
          |> Enum.sort_by(fn {line_id, _item} -> line_id end)
          |> Enum.map(fn {line_id, item} ->
            line = Map.get(catalog, line_id, %{})

            "#{get(line, :name, line_id)}: #{get(item, :on_hand, 0)} on hand at $#{money(get(item, :price, 0.0))}"
          end)
          |> Enum.join("\n")

        text = """
        #{lines}
        Singles case: #{get(singles, :cards_on_hand, 0)} raw cards, $#{money(get(singles, :total_market_value, 0.0))} market value
        Graded cards: #{length(get(singles, :graded_cards, []))}
        """

        tool_result(text, Events.inspected_inventory(map_size(inventory)))
      end
    }
  end

  defp research_market_tool do
    %AgentTool{
      name: "tcg_research_market",
      description:
        "Research franchise demand, sealed-product spreads, allocation risk, singles movement, or grading demand.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Market question to research"}
        },
        "required" => ["query"],
        "additionalProperties" => false
      },
      label: "Research Market",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        query = Map.get(params, "query", "")
        result_count = 4

        text = """
        Market notes for #{query}:
        - Pokemon demand is deep but price-sensitive near big-box restocks.
        - One Piece sealed supply is volatile; allocation wins can carry high margins.
        - Yu-Gi-Oh! singles spike after regional decklists, then decay quickly.
        - Dragon Ball Super has smaller volume but strong event conversion.
        """

        tool_result(text, Events.researched_market(query, result_count))
      end
    }
  end

  defp review_customers_tool(world) do
    %AgentTool{
      name: "tcg_review_customers",
      description: "Review the current customer queue and local play demand.",
      parameters: empty_params(),
      label: "Review Customers",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        queue = get(world, :customer_queue, [])

        text =
          queue
          |> Enum.map(fn customer ->
            "- #{get(customer, :type, "customer")}: #{get(customer, :need, "")} (#{get(customer, :urgency, "normal")})"
          end)
          |> Enum.join("\n")

        tool_result(text, Events.reviewed_customers(length(queue)))
      end
    }
  end

  defp order_product_line_tool do
    %AgentTool{
      name: "tcg_order_product_line",
      description: "Order sealed product or accessories from distribution. This spends cash now.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "line_id" => %{
            "type" => "string",
            "description" => "Product line to order",
            "enum" => Enum.map(Catalog.lines(), & &1.id)
          },
          "quantity" => %{"type" => "integer", "minimum" => 1, "maximum" => 120}
        },
        "required" => ["line_id", "quantity"],
        "additionalProperties" => false
      },
      label: "Order Product",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        line_id = Map.get(params, "line_id")
        quantity = Map.get(params, "quantity", 0)

        tool_result(
          "Ordered #{quantity} units of #{line_id}.",
          Events.order_product_line(line_id, quantity)
        )
      end
    }
  end

  defp buy_collection_tool do
    %AgentTool{
      name: "tcg_buy_collection",
      description:
        "Buy a local collection for the singles case. This ties cash into raw singles.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "franchise" => %{"type" => "string", "enum" => Catalog.franchises() -- ["Accessories"]},
          "budget" => %{"type" => "number", "minimum" => 50, "maximum" => 5000},
          "focus" => %{"type" => "string", "enum" => ["bulk", "playables", "chase", "mixed"]}
        },
        "required" => ["franchise", "budget", "focus"],
        "additionalProperties" => false
      },
      label: "Buy Collection",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        franchise = Map.get(params, "franchise")
        budget = Map.get(params, "budget", 0.0)
        focus = Map.get(params, "focus", "mixed")

        tool_result(
          "Bought a #{franchise} collection.",
          Events.buy_collection(franchise, budget, focus)
        )
      end
    }
  end

  defp set_prices_tool do
    %AgentTool{
      name: "tcg_set_prices",
      description:
        "Set shelf prices as a markup over current market price, optionally for one line.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "markup_pct" => %{"type" => "number", "minimum" => -20, "maximum" => 80},
          "line_id" => %{"type" => "string", "enum" => Enum.map(Catalog.lines(), & &1.id)}
        },
        "required" => ["markup_pct"],
        "additionalProperties" => false
      },
      label: "Set Prices",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        markup_pct = Map.get(params, "markup_pct", 0)
        line_id = Map.get(params, "line_id")
        tool_result("Updated prices by #{markup_pct}%.", Events.set_prices(markup_pct, line_id))
      end
    }
  end

  defp host_event_tool do
    %AgentTool{
      name: "tcg_host_event",
      description:
        "Run an in-store play event. Events cost prizes/staff but improve demand and sales.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "game" => %{"type" => "string", "enum" => Catalog.franchises() -- ["Accessories"]},
          "prize_budget" => %{"type" => "number", "minimum" => 0, "maximum" => 1000},
          "entry_fee" => %{"type" => "number", "minimum" => 0, "maximum" => 40}
        },
        "required" => ["game", "prize_budget", "entry_fee"],
        "additionalProperties" => false
      },
      label: "Host Event",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        game = Map.get(params, "game")
        prize_budget = Map.get(params, "prize_budget", 0.0)
        entry_fee = Map.get(params, "entry_fee", 0.0)
        tool_result("Hosted #{game} event.", Events.host_event(game, prize_budget, entry_fee))
      end
    }
  end

  defp submit_grading_tool do
    %AgentTool{
      name: "tcg_submit_grading",
      description:
        "Submit raw singles for grading. Cards return after a delay with higher value.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "card_count" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
          "service_level" => %{"type" => "string", "enum" => ["bulk", "standard", "express"]}
        },
        "required" => ["card_count", "service_level"],
        "additionalProperties" => false
      },
      label: "Submit Grading",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        count = Map.get(params, "card_count", 0)
        service = Map.get(params, "service_level", "bulk")

        tool_result(
          "Submitted #{count} cards for #{service} grading.",
          Events.submit_grading(count, service)
        )
      end
    }
  end

  defp process_online_orders_tool do
    %AgentTool{
      name: "tcg_process_online_orders",
      description:
        "Pack and ship online orders. Better packing costs more time but protects rating.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "packing_quality" => %{"type" => "string", "enum" => ["cheap", "standard", "premium"]}
        },
        "required" => ["packing_quality"],
        "additionalProperties" => false
      },
      label: "Process Online Orders",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        quality = Map.get(params, "packing_quality", "standard")

        tool_result(
          "Processed online orders with #{quality} packing.",
          Events.process_online_orders(quality)
        )
      end
    }
  end

  defp wait_next_day_tool do
    %AgentTool{
      name: "tcg_wait_next_day",
      description:
        "End the operating day. Deliveries, grading returns, rent, organic sales, and market movement resolve.",
      parameters: %{
        "type" => "object",
        "properties" => %{"reason" => %{"type" => "string"}},
        "required" => ["reason"],
        "additionalProperties" => false
      },
      label: "Next Day",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        tool_result(
          "Advanced to the next day.",
          Events.wait_next_day(Map.get(params, "reason", ""))
        )
      end
    }
  end

  defp tool_result(text, event) do
    {:ok,
     %AgentToolResult{
       content: [AgentCore.text_content(text)],
       details: %{"event" => event},
       trust: :trusted
     }}
  end

  defp empty_params do
    %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}
  end

  defp get(map, key, default) do
    MapHelpers.get_key(map, key) || default
  end

  defp money(value), do: :erlang.float_to_binary((value || 0) + 0.0, decimals: 2)
end
