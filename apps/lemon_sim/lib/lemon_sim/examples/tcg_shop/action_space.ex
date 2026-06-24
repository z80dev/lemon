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
      research_market_tool(world),
      review_customers_tool(world)
    ]
  end

  defp terminal_tools(_world) do
    [
      order_product_line_tool(),
      buy_collection_tool(),
      open_sealed_product_tool(),
      prepare_loose_packs_tool(),
      take_consignment_tool(),
      sell_memberships_tool(),
      schedule_staff_shift_tool(),
      upgrade_loss_prevention_tool(),
      manage_credit_line_tool(),
      make_bank_deposit_tool(),
      set_prices_tool(),
      host_event_tool(),
      take_preorders_tool(),
      take_special_order_tool(),
      run_promotion_tool(),
      manage_online_channel_tool(),
      file_supplier_claim_tool(),
      process_customer_return_tool(),
      submit_grading_tool(),
      process_online_orders_tool(),
      wait_next_day_tool()
    ]
  end

  defp check_dashboard_tool(world) do
    %AgentTool{
      name: "tcg_check_dashboard",
      description:
        "Check cash, net worth, reputation, current day, pending deliveries, preorders, and grading.",
      parameters: empty_params(),
      label: "Check Dashboard",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        day = get(world, :day_number, 1)
        balance = get(world, :bank_balance, 0.0)
        drawer = get(world, :cash_drawer_balance, 0.0)

        text = """
        Day #{day}/#{get(world, :max_days, 14)}
        Bank balance: $#{money(balance)}
        Cash drawer: $#{money(drawer)}
        Reputation: #{get(world, :reputation, 50)}/100
        Online rating: #{get(world, :online_rating, 4.3)}
        Staff hours remaining: #{money(get(get(world, :operations, %{}), :staff_hours_remaining, 0.0))}/#{money(get(get(world, :operations, %{}), :daily_staff_hours, 0.0))}
        Credit line: $#{money(get(world, :credit_line_balance, 0.0))}/$#{money(get(world, :credit_line_limit, 0.0))}
        Overtime hours: #{money(get(get(world, :operations, %{}), :cumulative_overtime_hours, 0.0))}
        Backlog tasks: #{length(get(get(world, :operations, %{}), :backlog_tasks, []))}
        Pending deliveries: #{length(get(world, :pending_deliveries, []))}
        Pending preorders: #{pending_preorder_units(world)} units
        Pending special orders: #{pending_special_order_units(world)} units, liability $#{money(get(world, :special_order_liability, 0.0))}
        Pending grading: #{length(get(world, :pending_grading, []))}
        Active memberships: #{active_membership_count(world)} members, liability $#{money(get(world, :membership_liability, 0.0))}
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

            "#{get(line, :name, line_id)}: #{get(item, :on_hand, 0)} on hand at $#{money(get(item, :price, 0.0))}, avg age #{money(get(item, :age_days, 0))}d"
          end)
          |> Enum.join("\n")

        text = """
        #{lines}
        Singles case: #{get(singles, :cards_on_hand, 0)} raw cards, $#{money(get(singles, :total_market_value, 0.0))} market value
        Graded cards: #{length(get(singles, :graded_cards, []))}
        Consignment lots: #{length(get(world, :consignment_lots, []))}, payable $#{money(get(world, :consignment_payable, 0.0))}
        Active memberships: #{active_membership_count(world)} members
        """

        tool_result(text, Events.inspected_inventory(map_size(inventory)))
      end
    }
  end

  defp research_market_tool(world) do
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
        notes = market_research_notes(world, query)
        result_count = length(notes)

        text = """
        Market notes for #{query}:
        #{Enum.map_join(notes, "\n", &("- " <> &1))}
        """

        tool_result(text, Events.researched_market(query, result_count, notes))
      end
    }
  end

  defp market_research_notes(world, query) do
    normalized = query |> to_string() |> String.downcase()
    pulse = List.last(get(world, :market_pulses, [])) || %{}
    position = get(world, :competitive_position, %{})

    base = [
      "Current pulse: #{get(pulse, :featured_franchise, "Unknown")} at #{money(get(pulse, :buzz_multiplier, 1.0))}x buzz; #{get(pulse, :note, "no release note")}.",
      "Local share is #{money(get(position, :local_market_share_pct, 34.0))}% with #{money(get(position, :competitor_pressure, 0.0))}/10 competitor pressure and #{get(position, :price_reputation, "fair")} price reputation.",
      "Use this as dated operating research, not a guarantee: it reflects visible local demand, releases, shelf prices, stockouts, and current distributor standing."
    ]

    topic_notes =
      cond do
        String.contains?(normalized, "allocation") or String.contains?(normalized, "supplier") ->
          [
            "Allocation-sensitive sealed lines depend on account standing and open AP; preferred distributor accounts improve fill rates while overdue invoices reduce access.",
            "One Piece and Pokemon sealed orders are the most sensitive to partial fills, so preorder promises should leave buffer stock."
          ]

        String.contains?(normalized, "single") or String.contains?(normalized, "grading") ->
          [
            "Singles liquidity improves with events and collector traffic, but raw-card value is not cash until sold and grading creates delayed inventory risk.",
            "Chase-focused collection buys can produce upside, but condition/authentication risk should be priced into the buy."
          ]

        String.contains?(normalized, "online") or String.contains?(normalized, "shipping") ->
          [
            "TCGplayer and eBay increase demand reach but add marketplace fees, shipping labels, packing cost, and rating risk from backorders or cheap packing.",
            "Optimized listings help only when inventory depth can support fulfillment without repeated stockouts."
          ]

        String.contains?(normalized, "event") or String.contains?(normalized, "league") ->
          [
            "Organized play converts community traffic into accessory and pack sales, but prize support and judge labor can erase weak entry-fee economics.",
            "No-shows and turn-aways are capacity signals; use them to tune prize budgets, staffing, and table space."
          ]

        String.contains?(normalized, "cash") or String.contains?(normalized, "credit") ->
          [
            "Cash is split between bank and drawer; high drawer balances create reconciliation exposure while AP and credit-line debt reduce true net worth.",
            "Working capital is useful around releases, but interest and supplier credit use should be visible in the scorecard before expanding commitments."
          ]

        true ->
          [
            "Pokemon demand is deep but price-sensitive near big-box restocks.",
            "One Piece sealed supply is volatile; allocation wins can carry high margins but also preorder risk.",
            "Yu-Gi-Oh! singles spike after regional decklists, then decay quickly.",
            "Dragon Ball Super has smaller volume but strong event conversion."
          ]
      end

    base ++ topic_notes
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
            "- #{get(customer, :name, get(customer, :type, "customer"))}: #{get(customer, :need, "")} (#{get(customer, :urgency, "normal")}, loyalty #{get(customer, :loyalty, "?")}, satisfaction #{get(customer, :satisfaction, "?")})"
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

  defp open_sealed_product_tool do
    %AgentTool{
      name: "tcg_open_sealed_product",
      description:
        "Open sealed booster product into the singles case. This consumes sealed inventory and staff time, creating raw singles market value with deterministic pull variance.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "line_id" => %{
            "type" => "string",
            "description" => "Sealed product line to open",
            "enum" =>
              Catalog.lines()
              |> Enum.filter(&(&1.category == "sealed"))
              |> Enum.map(& &1.id)
          },
          "quantity" => %{"type" => "integer", "minimum" => 1, "maximum" => 12}
        },
        "required" => ["line_id", "quantity"],
        "additionalProperties" => false
      },
      label: "Open Sealed",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        line_id = Map.get(params, "line_id")
        quantity = Map.get(params, "quantity", 0)

        tool_result(
          "Opened #{quantity} units of #{line_id} into singles.",
          Events.open_sealed_product(line_id, quantity)
        )
      end
    }
  end

  defp prepare_loose_packs_tool do
    %AgentTool{
      name: "tcg_prepare_loose_packs",
      description:
        "Break sealed booster product into loose pack inventory for counter sales and event impulse buys. This consumes sealed inventory but preserves retail value as packs.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "line_id" => %{"type" => "string", "enum" => sealed_line_ids()},
          "quantity" => %{"type" => "integer", "minimum" => 1, "maximum" => 12},
          "pack_price" => %{"type" => "number", "minimum" => 2, "maximum" => 15}
        },
        "required" => ["line_id", "quantity", "pack_price"],
        "additionalProperties" => false
      },
      label: "Prepare Packs",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        line_id = Map.get(params, "line_id")
        quantity = Map.get(params, "quantity", 0)
        pack_price = Map.get(params, "pack_price", 0.0)

        tool_result(
          "Prepared #{quantity} #{line_id} into loose packs at $#{money(pack_price)}.",
          Events.prepare_loose_packs(line_id, quantity, pack_price)
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

  defp take_consignment_tool do
    %AgentTool{
      name: "tcg_take_consignment",
      description:
        "Accept customer-owned singles on consignment. The shop earns commission when cards sell and owes the consignor the remaining payout.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "franchise" => %{"type" => "string", "enum" => Catalog.franchises() -- ["Accessories"]},
          "card_count" => %{"type" => "integer", "minimum" => 1, "maximum" => 80},
          "estimated_value" => %{"type" => "number", "minimum" => 25, "maximum" => 5000},
          "commission_pct" => %{"type" => "number", "minimum" => 5, "maximum" => 30}
        },
        "required" => ["franchise", "card_count", "estimated_value", "commission_pct"],
        "additionalProperties" => false
      },
      label: "Take Consignment",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        franchise = Map.get(params, "franchise")
        card_count = Map.get(params, "card_count", 0)
        estimated_value = Map.get(params, "estimated_value", 0.0)
        commission_pct = Map.get(params, "commission_pct", 15.0)

        tool_result(
          "Accepted #{card_count} #{franchise} cards on consignment.",
          Events.take_consignment(franchise, card_count, estimated_value, commission_pct)
        )
      end
    }
  end

  defp sell_memberships_tool do
    %AgentTool{
      name: "tcg_sell_memberships",
      description:
        "Sell paid league memberships or passes. Cash is collected now, then recognized as service revenue over the membership term.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "franchise" => %{"type" => "string", "enum" => Catalog.franchises() -- ["Accessories"]},
          "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 80},
          "fee" => %{"type" => "number", "minimum" => 5, "maximum" => 250},
          "duration_days" => %{"type" => "integer", "minimum" => 1, "maximum" => 30}
        },
        "required" => ["franchise", "count", "fee", "duration_days"],
        "additionalProperties" => false
      },
      label: "Sell Memberships",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        franchise = Map.get(params, "franchise")
        count = Map.get(params, "count", 0)
        fee = Map.get(params, "fee", 0.0)
        duration_days = Map.get(params, "duration_days", 0)

        tool_result(
          "Sold #{count} #{franchise} memberships.",
          Events.sell_memberships(franchise, count, fee, duration_days)
        )
      end
    }
  end

  defp schedule_staff_shift_tool do
    %AgentTool{
      name: "tcg_schedule_staff_shift",
      description:
        "Schedule part-time store help for the current day. This spends cash now and adds staff hours to reduce overtime, fatigue, and backlog risk.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "role" => %{
            "type" => "string",
            "enum" => ["sales_floor", "sorting", "event_judge", "online_fulfillment"]
          },
          "hours" => %{"type" => "number", "minimum" => 1, "maximum" => 10}
        },
        "required" => ["role", "hours"],
        "additionalProperties" => false
      },
      label: "Schedule Staff",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        role = Map.get(params, "role")
        hours = Map.get(params, "hours", 0.0)

        tool_result(
          "Scheduled #{hours} hours of #{role} coverage.",
          Events.schedule_staff_shift(role, hours)
        )
      end
    }
  end

  defp upgrade_loss_prevention_tool do
    %AgentTool{
      name: "tcg_upgrade_loss_prevention",
      description:
        "Invest in shop loss-prevention controls. This spends cash now and lowers future shrinkage risk from theft, mishandling, and poor inventory controls.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "control" => %{
            "type" => "string",
            "enum" => ["display_case_locks", "camera_system", "inventory_audit_process"]
          }
        },
        "required" => ["control"],
        "additionalProperties" => false
      },
      label: "Upgrade Security",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        control = Map.get(params, "control")

        tool_result(
          "Upgraded loss prevention with #{control}.",
          Events.upgrade_loss_prevention(control)
        )
      end
    }
  end

  defp manage_credit_line_tool do
    %AgentTool{
      name: "tcg_manage_credit_line",
      description:
        "Draw or repay the shop working-capital credit line. Draws add cash and debt; repayments reduce cash and debt.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["draw", "repay"]},
          "amount" => %{"type" => "number", "minimum" => 50, "maximum" => 3000},
          "reason" => %{"type" => "string"}
        },
        "required" => ["action", "amount", "reason"],
        "additionalProperties" => false
      },
      label: "Credit Line",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        action = Map.get(params, "action")
        amount = Map.get(params, "amount", 0.0)
        reason = Map.get(params, "reason", "")

        tool_result(
          "#{String.capitalize(to_string(action))} credit line $#{money(amount)}.",
          Events.manage_credit_line(action, amount, reason)
        )
      end
    }
  end

  defp make_bank_deposit_tool do
    %AgentTool{
      name: "tcg_make_bank_deposit",
      description:
        "Deposit register cash into the bank. This reduces cash kept on premises and increases bank balance.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "number", "minimum" => 1, "maximum" => 5000},
          "reason" => %{"type" => "string"}
        },
        "required" => ["amount", "reason"],
        "additionalProperties" => false
      },
      label: "Bank Deposit",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        amount = Map.get(params, "amount", 0.0)
        reason = Map.get(params, "reason", "")

        tool_result(
          "Deposited $#{money(amount)} from the cash drawer.",
          Events.make_bank_deposit(amount, reason)
        )
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
          "entry_fee" => %{"type" => "number", "minimum" => 0, "maximum" => 40},
          "sanctioned" => %{"type" => "boolean"}
        },
        "required" => ["game", "prize_budget", "entry_fee"],
        "additionalProperties" => false
      },
      label: "Host Event",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        game = Map.get(params, "game")
        prize_budget = Map.get(params, "prize_budget", 0.0)
        entry_fee = Map.get(params, "entry_fee", 0.0)
        sanctioned = Map.get(params, "sanctioned", true)

        tool_result(
          "Hosted #{game} event.",
          Events.host_event(game, prize_budget, entry_fee, sanctioned)
        )
      end
    }
  end

  defp take_preorders_tool do
    %AgentTool{
      name: "tcg_take_preorders",
      description:
        "Take customer preorder deposits for sealed product tied to the next release window.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "line_id" => %{
            "type" => "string",
            "description" => "Sealed product line to reserve",
            "enum" =>
              Catalog.lines()
              |> Enum.filter(&(&1.category == "sealed"))
              |> Enum.map(& &1.id)
          },
          "quantity" => %{"type" => "integer", "minimum" => 1, "maximum" => 80},
          "deposit_pct" => %{"type" => "number", "minimum" => 10, "maximum" => 100}
        },
        "required" => ["line_id", "quantity", "deposit_pct"],
        "additionalProperties" => false
      },
      label: "Take Preorders",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        line_id = Map.get(params, "line_id")
        quantity = Map.get(params, "quantity", 0)
        deposit_pct = Map.get(params, "deposit_pct", 25.0)

        tool_result(
          "Reserved #{quantity} units of #{line_id} with #{deposit_pct}% deposits.",
          Events.take_preorders(line_id, quantity, deposit_pct)
        )
      end
    }
  end

  defp take_special_order_tool do
    %AgentTool{
      name: "tcg_take_special_order",
      description:
        "Take a customer special order or hold for any stocked product line. The shop collects a deposit now, reserves units from walk-in demand, and fulfills from available or incoming inventory.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "line_id" => %{
            "type" => "string",
            "description" => "Product line the customer wants held or sourced",
            "enum" => Enum.map(Catalog.lines(), & &1.id)
          },
          "quantity" => %{"type" => "integer", "minimum" => 1, "maximum" => 24},
          "deposit_pct" => %{"type" => "number", "minimum" => 10, "maximum" => 100}
        },
        "required" => ["line_id", "quantity", "deposit_pct"],
        "additionalProperties" => false
      },
      label: "Special Order",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        line_id = Map.get(params, "line_id")
        quantity = Map.get(params, "quantity", 0)
        deposit_pct = Map.get(params, "deposit_pct", 25.0)

        tool_result(
          "Took a #{quantity}-unit special order for #{line_id}.",
          Events.take_special_order(line_id, quantity, deposit_pct)
        )
      end
    }
  end

  defp run_promotion_tool do
    %AgentTool{
      name: "tcg_run_promotion",
      description:
        "Run a short marketing or community campaign for one franchise. This spends cash now and boosts matching demand while active.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "franchise" => %{"type" => "string", "enum" => Catalog.franchises() -- ["Accessories"]},
          "channel" => %{
            "type" => "string",
            "enum" => ["social_ads", "email_list", "community_flyers", "creator_sponsorship"]
          },
          "budget" => %{"type" => "number", "minimum" => 25, "maximum" => 1500},
          "duration_days" => %{"type" => "integer", "minimum" => 1, "maximum" => 7}
        },
        "required" => ["franchise", "channel", "budget", "duration_days"],
        "additionalProperties" => false
      },
      label: "Run Promotion",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        franchise = Map.get(params, "franchise")
        channel = Map.get(params, "channel", "social_ads")
        budget = Map.get(params, "budget", 0.0)
        duration_days = Map.get(params, "duration_days", 1)

        tool_result(
          "Started #{channel} promotion for #{franchise}.",
          Events.run_promotion(franchise, channel, budget, duration_days)
        )
      end
    }
  end

  defp manage_online_channel_tool do
    %AgentTool{
      name: "tcg_manage_online_channel",
      description:
        "Configure the shop's online selling channel and listing quality. Better marketplaces and listings raise online demand but add marketplace fees and setup work.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "platform" => %{"type" => "string", "enum" => ["local_pickup", "tcgplayer", "ebay"]},
          "listing_quality" => %{"type" => "string", "enum" => ["basic", "optimized", "premium"]}
        },
        "required" => ["platform", "listing_quality"],
        "additionalProperties" => false
      },
      label: "Manage Online Channel",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        platform = Map.get(params, "platform")
        listing_quality = Map.get(params, "listing_quality")

        tool_result(
          "Configured #{platform} listings at #{listing_quality} quality.",
          Events.manage_online_channel(platform, listing_quality)
        )
      end
    }
  end

  defp file_supplier_claim_tool do
    %AgentTool{
      name: "tcg_file_supplier_claim",
      description:
        "File a distributor claim for damaged units found during receiving. Approved claims credit the matching open invoice or reimburse cash if already paid.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "invoice_id" => %{
            "type" => "string",
            "description" => "Supplier invoice id from the damaged receipt"
          },
          "damaged_units" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
        },
        "required" => ["invoice_id", "damaged_units"],
        "additionalProperties" => false
      },
      label: "File Supplier Claim",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        invoice_id = Map.get(params, "invoice_id")
        damaged_units = Map.get(params, "damaged_units", 0)

        tool_result(
          "Filed supplier claim for #{damaged_units} damaged units on #{invoice_id}.",
          Events.file_supplier_claim(invoice_id, damaged_units)
        )
      end
    }
  end

  defp process_customer_return_tool do
    %AgentTool{
      name: "tcg_process_customer_return",
      description:
        "Process a local customer return against prior walk-in or preorder sales. Resellable sealed returns restock inventory; opened or damaged returns create writeoff loss. Store-credit resolutions preserve cash but increase liability.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "line_id" => %{"type" => "string", "enum" => Enum.map(Catalog.lines(), & &1.id)},
          "quantity" => %{"type" => "integer", "minimum" => 1, "maximum" => 20},
          "condition" => %{
            "type" => "string",
            "enum" => ["sealed_resellable", "opened", "damaged"]
          },
          "resolution" => %{"type" => "string", "enum" => ["store_credit", "cash_refund"]}
        },
        "required" => ["line_id", "quantity", "condition", "resolution"],
        "additionalProperties" => false
      },
      label: "Customer Return",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        line_id = Map.get(params, "line_id")
        quantity = Map.get(params, "quantity", 0)
        condition = Map.get(params, "condition", "sealed_resellable")
        resolution = Map.get(params, "resolution", "store_credit")

        tool_result(
          "Processed #{quantity} #{condition} returns for #{line_id} as #{resolution}.",
          Events.process_customer_return(line_id, quantity, condition, resolution)
        )
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

  defp pending_preorder_units(world) do
    world
    |> get(:pending_preorders, [])
    |> Enum.reduce(0, fn preorder, acc -> acc + get(preorder, :remaining_quantity, 0) end)
  end

  defp pending_special_order_units(world) do
    world
    |> get(:pending_special_orders, [])
    |> Enum.reduce(0, fn order, acc -> acc + get(order, :remaining_quantity, 0) end)
  end

  defp active_membership_count(world) do
    world
    |> get(:active_memberships, [])
    |> Enum.filter(&(get(&1, :status, "active") == "active"))
    |> Enum.reduce(0, fn batch, acc -> acc + get(batch, :member_count, 0) end)
  end

  defp money(value), do: :erlang.float_to_binary((value || 0) + 0.0, decimals: 2)

  defp sealed_line_ids do
    Catalog.lines()
    |> Enum.filter(&(&1.category == "sealed"))
    |> Enum.map(& &1.id)
  end
end
