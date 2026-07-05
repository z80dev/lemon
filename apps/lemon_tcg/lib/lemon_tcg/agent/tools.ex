defmodule LemonTcg.Agent.Tools do
  @moduledoc """
  `AgentCore.Types.AgentTool` surface for operating a `LemonTcg.Desk`.

  Mirrors the sim's `LemonSim.Examples.TcgShop.ActionSpace` naming
  (`tcg_live_*`) so an agent trained against the sim maps straight onto
  the live desk. Read-only tools (dashboard, floor, listings) are support
  tools; buy/sell are the terminal actions. Risk limits are enforced by
  the desk — a blocked order comes back as a tool error the agent can read.

  Every result carries an event map in `details["event"]` so the sim
  kernel's `ExecutedCallEvents` adapter can drive `LemonTcg.Agent.Updater`
  from the same tool executions.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonTcg.Desk

  @doc "Build the tool list bound to a running desk process."
  @spec build(GenServer.server()) :: [AgentTool.t()]
  def build(desk) do
    [
      dashboard_tool(desk),
      floor_tool(desk),
      listings_tool(desk),
      check_comp_tool(desk),
      price_basis_tool(desk),
      buy_tool(desk),
      sell_tool(desk),
      halt_tool(desk)
    ]
  end

  @doc "Names of tools that only read state (for `support_tool_matcher`)."
  def support_tool?(%{name: name}),
    do:
      name in ~w(tcg_live_dashboard tcg_live_floor tcg_live_listings tcg_live_check_comp tcg_live_price_basis)

  def support_tool?(_), do: false

  defp dashboard_tool(desk) do
    %AgentTool{
      name: "tcg_live_dashboard",
      description:
        "Check cash, positions, mark-to-market net worth, risk policy, and watchlist floors.",
      parameters: empty_params(),
      label: "Desk Dashboard",
      execute: fn _id, _params, _signal, _on_update ->
        snapshot = Desk.snapshot(desk)
        mark = snapshot.mark

        positions =
          snapshot.positions
          |> Enum.map_join("\n", fn p ->
            "  #{p.mint} (#{p.collection}) cost $#{p.cost_basis_usd}"
          end)

        text = """
        Venue: #{snapshot.venue}
        Cash: $#{mark.cash_usd}
        Inventory: $#{mark.inventory_value_usd} across #{mark.position_count} positions (#{mark.unpriced_positions} unpriced)
        Net worth: $#{mark.net_worth_usd}
        Realized P&L: $#{mark.realized_pnl_usd} | Unrealized: $#{mark.unrealized_pnl_usd} | Fees: $#{mark.fees_usd}
        Kill switch: #{snapshot.policy.kill_switch}
        Watchlist floors (USD): #{inspect(snapshot.floors_usd)}
        Positions:
        #{if positions == "", do: "  (none)", else: positions}
        """

        text_result(text, "tcg_live_checked_dashboard", %{
          "net_worth_usd" => mark.net_worth_usd,
          "cash_usd" => mark.cash_usd,
          "position_count" => mark.position_count
        })
      end
    }
  end

  defp floor_tool(desk) do
    %AgentTool{
      name: "tcg_live_floor",
      description: "Get the current floor price for a collection on the desk's market source.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "collection" => %{"type" => "string", "description" => "Collection symbol."}
        },
        "required" => ["collection"],
        "additionalProperties" => false
      },
      label: "Check Floor",
      execute: fn _id, params, _signal, _on_update ->
        collection = Map.get(params, "collection", "")

        case Desk.floor(desk, collection) do
          {:ok, floor} ->
            text_result(
              "#{collection} floor: #{floor.floor_sol} SOL " <>
                "(#{floor.listed_count || "?"} listed, venue #{floor.venue})",
              "tcg_live_checked_floor",
              %{"collection" => collection, "floor_sol" => floor.floor_sol}
            )

          {:error, reason} ->
            error_result("Floor lookup failed: #{inspect(reason)}", "check_floor", collection)
        end
      end
    }
  end

  defp listings_tool(desk) do
    %AgentTool{
      name: "tcg_live_listings",
      description: "List the cheapest current asks for a collection (mint, name, price in SOL).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "collection" => %{"type" => "string", "description" => "Collection symbol."},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
        },
        "required" => ["collection"],
        "additionalProperties" => false
      },
      label: "Browse Listings",
      execute: fn _id, params, _signal, _on_update ->
        collection = Map.get(params, "collection", "")
        limit = Map.get(params, "limit", 10)

        case Desk.listings(desk, collection, limit) do
          {:ok, listings} ->
            lines =
              Enum.map_join(listings, "\n", fn l ->
                "#{l.mint} | #{l.name || "unnamed"} | #{l.price_sol} SOL"
              end)

            text_result(
              if(lines == "", do: "No live listings.", else: lines),
              "tcg_live_checked_listings",
              %{"collection" => collection, "count" => length(listings)}
            )

          {:error, reason} ->
            error_result("Listings lookup failed: #{inspect(reason)}", "check_listings", collection)
        end
      end
    }
  end

  defp check_comp_tool(desk) do
    %AgentTool{
      name: "tcg_live_check_comp",
      description:
        "Look up what a card sells for in the physical market, by grade. " <>
          "Pass the card name (include the grade, e.g. 'Charizard Base Set PSA 9') " <>
          "or set grade separately.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Card name to comp."},
          "grade" => %{
            "type" => "string",
            "description" => "Grade label like 'PSA 10' or 'ungraded'. Optional."
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      },
      label: "Check Physical Comp",
      execute: fn _id, params, _signal, _on_update ->
        query = Map.get(params, "query", "")

        case Desk.comp(desk, query, Map.get(params, "grade")) do
          {:ok, matched} ->
            text_result(
              "#{matched.comp.name || query} (#{matched.comp.set || "unknown set"}): " <>
                "$#{matched.price_usd} for bucket #{matched.bucket} " <>
                "(source #{matched.comp.source}). All buckets: #{inspect(matched.comp.prices)}",
              "tcg_live_checked_comp",
              %{"query" => query, "bucket" => matched.bucket, "price_usd" => matched.price_usd}
            )

          {:error, reason} ->
            error_result("Comp lookup failed: #{inspect(reason)}", "check_comp", query)
        end
      end
    }
  end

  defp price_basis_tool(desk) do
    %AgentTool{
      name: "tcg_live_price_basis",
      description:
        "Evaluate a live listing against its physical comp: full " <>
          "buy token → redeem → sell physical round trip, net of taker fee, " <>
          "redemption fee, shipping, and physical marketplace fees. " <>
          "Use before buying — a discount to comp can still be a negative-edge trade.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "collection" => %{"type" => "string"},
          "mint" => %{"type" => "string", "description" => "Listed token mint to evaluate."},
          "query" => %{"type" => "string", "description" => "Card name to comp against."},
          "grade" => %{
            "type" => "string",
            "description" => "Grade label like 'PSA 10'. Optional; parsed from query otherwise."
          }
        },
        "required" => ["collection", "mint", "query"],
        "additionalProperties" => false
      },
      label: "Price Basis",
      execute: fn _id, params, _signal, _on_update ->
        collection = Map.get(params, "collection", "")
        mint = Map.get(params, "mint", "")
        query = Map.get(params, "query", "")

        case Desk.basis(desk, collection, mint, query, Map.get(params, "grade")) do
          {:ok, basis} ->
            text_result(
              """
              Basis for #{basis.mint} (#{basis.listing_name || "unnamed"}) vs #{basis.comp_name || query} [#{basis.comp_bucket}]:
              Token ask $#{basis.token_ask_usd} → all-in cost $#{basis.token_cost_usd}
              Physical comp $#{basis.comp_usd} → net after sell fees $#{basis.physical_net_usd}, redemption cost $#{basis.redemption_cost_usd}
              Discount to comp: #{basis.discount_to_comp_pct}%
              Round-trip edge: $#{basis.edge_usd} (#{basis.edge_pct}% on cost) — #{basis.verdict}
              """,
              "tcg_live_priced_basis",
              %{
                "mint" => mint,
                "query" => query,
                "edge_usd" => basis.edge_usd,
                "edge_pct" => basis.edge_pct,
                "verdict" => basis.verdict
              }
            )

          {:error, reason} ->
            error_result("Basis evaluation failed: #{inspect(reason)}", "price_basis", mint)
        end
      end
    }
  end

  defp buy_tool(desk) do
    %AgentTool{
      name: "tcg_live_buy",
      description:
        "Buy one listed token at its current ask. Goes through risk checks; " <>
          "blocked orders return the reason.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "collection" => %{"type" => "string"},
          "mint" => %{"type" => "string", "description" => "Token mint address to buy."}
        },
        "required" => ["collection", "mint"],
        "additionalProperties" => false
      },
      label: "Buy Token",
      execute: fn _id, params, _signal, _on_update ->
        collection = Map.get(params, "collection", "")
        mint = Map.get(params, "mint", "")

        case Desk.buy(desk, collection, mint) do
          {:ok, fill} ->
            text_result(
              "Bought #{fill.mint} for $#{fill.price_usd} (+$#{fill.fee_usd} fee) on #{fill.venue}. Tx: #{fill.txid}",
              "tcg_live_bought",
              fill_payload(fill)
            )

          {:error, reason} ->
            error_result("Buy rejected: #{inspect(reason)}", "buy", mint)
        end
      end
    }
  end

  defp sell_tool(desk) do
    %AgentTool{
      name: "tcg_live_sell",
      description: "Sell a held position at the current floor (exit haircut and fee apply).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "mint" => %{"type" => "string", "description" => "Held token mint to sell."}
        },
        "required" => ["mint"],
        "additionalProperties" => false
      },
      label: "Sell Token",
      execute: fn _id, params, _signal, _on_update ->
        mint = Map.get(params, "mint", "")

        case Desk.sell(desk, mint) do
          {:ok, fill} ->
            text_result(
              "Sold #{fill.mint} for $#{fill.price_usd} (-$#{fill.fee_usd} fee) on #{fill.venue}. Tx: #{fill.txid}",
              "tcg_live_sold",
              fill_payload(fill)
            )

          {:error, reason} ->
            error_result("Sell rejected: #{inspect(reason)}", "sell", mint)
        end
      end
    }
  end

  defp halt_tool(desk) do
    %AgentTool{
      name: "tcg_live_halt",
      description:
        "Engage the kill switch: stop all buying immediately. Selling stays available. " <>
          "Use when market data looks wrong or losses are mounting.",
      parameters: empty_params(),
      label: "Halt Buying",
      execute: fn _id, _params, _signal, _on_update ->
        :ok = Desk.halt(desk)

        text_result(
          "Kill switch engaged. Buys are blocked; sells remain available.",
          "tcg_live_halted",
          %{}
        )
      end
    }
  end

  defp text_result(text, event_kind, payload) do
    {:ok,
     %AgentToolResult{
       content: [AgentCore.text_content(text)],
       details: %{"event" => %{"kind" => event_kind, "payload" => payload}},
       trust: :trusted
     }}
  end

  defp error_result(text, action, subject) do
    {:ok,
     %AgentToolResult{
       content: [AgentCore.text_content(text)],
       details: %{
         "error" => true,
         "event" => %{
           "kind" => "tcg_live_action_rejected",
           "payload" => %{"action" => action, "subject" => subject, "reason" => text}
         }
       },
       trust: :trusted
     }}
  end

  defp fill_payload(fill) do
    %{
      "mint" => fill.mint,
      "collection" => fill.collection,
      "price_usd" => fill.price_usd,
      "fee_usd" => fill.fee_usd,
      "venue" => fill.venue,
      "txid" => fill.txid
    }
  end

  defp empty_params do
    %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}
  end
end
