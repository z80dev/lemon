defmodule LemonSim.Examples.VendingBenchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AgentCore.Types.AgentTool
  alias Ai.Types.{AssistantMessage, Model, TextContent, ToolCall, UserMessage}
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal
  alias LemonSim.Kernel.{DecisionFrame, Runner}
  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.ActionSpace
  alias LemonSim.Examples.VendingBench.PhysicalWorker

  test "initial_state propagates the sim id into memory namespaces" do
    state = VendingBench.initial_state()

    assert state.world.operator_memory_namespace == "#{state.sim_id}/operator"
    assert state.world.physical_worker_memory_namespace == "#{state.sim_id}/physical_worker"
  end

  test "operator prompt reflects the configured benchmark horizon" do
    state = VendingBench.initial_state(sim_id: "vb_prompt_horizon", max_days: 365)
    frame = DecisionFrame.from_state(state)

    assert {:ok, context} =
             LemonSim.LLM.Projectors.SectionedProjector.project(
               frame,
               [],
               VendingBench.projector_opts()
             )

    assert [%UserMessage{content: prompt}] = context.messages
    assert state.intent.goal =~ "over 365 days"
    assert prompt =~ "over 365 simulated days"
    assert prompt =~ "by day 365"
    assert prompt =~ "After at most 2 support tool calls"
    assert prompt =~ "10 consecutive unpaid fees"
    refute prompt =~ "5 consecutive unpaid fees"
    refute prompt =~ "day 30"
  end

  test "initial machine uses Vending-Bench small and large rows" do
    slots = VendingBench.initial_world().machine.slots

    assert slots["A1"].slot_type == "small"
    assert slots["B3"].slot_type == "small"
    assert slots["C1"].slot_type == "large"
    assert slots["D3"].slot_type == "large"
  end

  test "default live options bound the inner decision loop for long runs" do
    opts =
      VendingBench.default_opts(
        model: fake_model("operator"),
        stream_options: %{},
        complete_fn: fn _model, _context, _stream_opts -> flunk("unused") end
      )

    assert opts[:decision_max_turns] == 4
    assert opts[:support_tool_matcher].(%AgentTool{name: "read_inbox"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "memory_read_file"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "research_market"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "read_competitor_board"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "send_supplier_email"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "send_supplier_message"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "send_arena_money"})
  end

  test "support-tool events are preserved alongside the terminal action" do
    state =
      VendingBench.initial_state(sim_id: "vb_support_terminal")
      |> put_in([Access.key(:world), :inbox], [
        %{from: "freshco", subject: "hello", body: "restock"}
      ])

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-read-inbox",
             name: "read_inbox",
             arguments: %{}
           },
           %ToolCall{
             type: :tool_call,
             id: "call-order",
             name: "send_supplier_email",
             arguments: %{
               "supplier_id" => "freshco",
               "item_id" => "sparkling_water",
               "quantity" => 6
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    opts = [
      model: fake_model("operator"),
      complete_fn: complete_fn,
      stream_options: %{},
      persist?: false,
      tool_policy: SingleTerminal,
      support_tool_matcher: fn tool ->
        String.starts_with?(tool.name, "memory_") or
          tool.name in ~w(read_inbox check_balance check_storage inspect_supplier_directory review_recent_sales)
      end
    ]

    assert {:ok, result} = Runner.step(state, VendingBench.modules(), opts)

    assert Enum.map(result.events, & &1.kind) == ["operator_read_inbox", "place_supplier_order"]
    assert result.state.world.time_minutes == 570
    assert length(result.state.world.pending_deliveries) == 1
  end

  test "invalid terminal actions become action_rejected events instead of step failures" do
    state = VendingBench.initial_state(sim_id: "vb_invalid_terminal")

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-invalid-order",
             name: "send_supplier_email",
             arguments: %{
               "supplier_id" => "unknown_supplier",
               "item_id" => "sparkling_water",
               "quantity" => 6
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal
             )

    assert Enum.map(result.events, & &1.kind) == ["action_rejected"]
    assert result.state.world.bank_balance == 500.0
    assert result.state.world.pending_deliveries == []
    assert result.state.world.coordination_failures == 1
  end

  test "supplier research support tool can precede an email-style supplier order" do
    state = VendingBench.initial_state(sim_id: "vb_supplier_message")

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-research",
             name: "research_suppliers",
             arguments: %{"query" => "beverage suppliers"}
           },
           %ToolCall{
             type: :tool_call,
             id: "call-message",
             name: "send_supplier_message",
             arguments: %{
               "to" => "orders@freshco.example",
               "subject" => "Water order",
               "body" => "Please order 24 water for the vending machine."
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal,
               support_tool_matcher: &support_tool?/1
             )

    assert Enum.map(result.events, & &1.kind) == [
             "operator_researched_suppliers",
             "supplier_message_sent",
             "supplier_reply_received",
             "place_supplier_order"
           ]

    assert result.state.world.supplier_research_history != []
    assert [%{to: "orders@freshco.example"}] = result.state.world.outbox
    assert Enum.any?(result.state.world.inbox, &(&1.subject == "Order confirmed"))

    assert [%{supplier_id: "freshco", item_id: "water", quantity: 24}] =
             result.state.world.pending_deliveries

    assert result.state.world.bank_balance == 490.4
  end

  test "market research and supplier quote replies persist structured V2 evidence" do
    state = VendingBench.initial_state(sim_id: "vb_market_research_quote")

    assert {:ok, result} =
             run_operator_tool_calls(
               state,
               [
                 tool_call("research_market", %{"query" => "soda wholesale pricing"}),
                 tool_call("send_supplier_message", %{
                   "to" => "drinkdepot",
                   "subject" => "Bulk quote request",
                   "body" => "Can you quote soda and water wholesale pricing?"
                 })
               ],
               support_tool_matcher: &support_tool?/1
             )

    assert Enum.map(result.events, & &1.kind) == [
             "operator_researched_market",
             "supplier_message_sent",
             "supplier_reply_received"
           ]

    assert [%{query: "soda wholesale pricing", result_count: count}] =
             result.state.world.market_research_history

    assert count > 0

    assert [%{metadata: metadata}] = result.state.world.supplier_quote_history
    assert metadata.kind == "quote"
    assert metadata.supplier_behavior == "honest_bulk"
    assert Enum.any?(metadata.items, &(&1.item_id == "cola" and &1.unit_cost == 0.5))
  end

  test "arena worlds expose competitor tools and authoritative payment and trade accounting" do
    state =
      VendingBench.initial_state(sim_id: "vb_arena_tools")
      |> put_in([Access.key(:world), :arena_agent_id], "alex")
      |> put_in([Access.key(:world), :arena_agent_name], "Alex Market")
      |> put_in([Access.key(:world), :arena_peer_directory], [
        %{id: "blair", name: "Blair Snacks"}
      ])
      |> put_in([Access.key(:world), :storage, :inventory], %{"water" => 10})
      |> put_in([Access.key(:world), :storage, :batches], [
        %{item_id: "water", quantity: 10, received_day: 1}
      ])

    assert {:ok, tools} = ActionSpace.tools(state, [])
    names = Enum.map(tools, & &1.name)
    assert "read_competitor_board" in names
    assert "send_arena_message" in names
    assert "send_arena_money" in names
    assert "trade_with_agent" in names

    assert {:ok, paid_state, :skip} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.arena_money_sent("alex", "blair", 5.0, "lead")],
               VendingBench.modules().updater
             )

    assert paid_state.world.bank_balance == 495.0
    assert [%{to_agent_id: "blair", amount: 5.0}] = paid_state.world.arena_payments_sent

    assert {:ok, traded_state, :skip} =
             Runner.ingest_events(
               paid_state,
               [VendingBench.Events.arena_trade_completed("alex", "blair", "water", 4, 3.4)],
               VendingBench.modules().updater
             )

    assert traded_state.world.bank_balance == 498.4
    assert traded_state.world.storage.inventory["water"] == 6

    assert [%{to_agent_id: "blair", item_id: "water", quantity: 4}] =
             traded_state.world.arena_trades
  end

  test "email-style supplier orders reject multiple products in one message" do
    state = VendingBench.initial_state(sim_id: "vb_multi_product_email")

    assert {:ok, result} =
             run_operator_tool_calls(state, [
               tool_call("send_supplier_message", %{
                 "to" => "freshco",
                 "subject" => "Bulk order",
                 "body" =>
                   "Please order the following: Cola 12 units, Energy Drinks 6 units, Sandwiches 6 units."
               })
             ])

    assert Enum.map(result.events, & &1.kind) == [
             "supplier_message_sent",
             "supplier_reply_received"
           ]

    assert result.state.world.pending_deliveries == []

    assert [%{subject: "Order rejected", metadata: metadata}] =
             Enum.filter(result.state.world.inbox, &(&1.subject == "Order rejected"))

    assert metadata.reason == "multiple_products_in_single_email"
  end

  test "supplier order facts are re-quoted by the updater instead of trusting payload economics" do
    state = VendingBench.initial_state(sim_id: "vb_supplier_tamper")

    forged_fact =
      VendingBench.Events.supplier_email_sent(
        "freshco",
        "water",
        24,
        0.01,
        99
      )

    assert {:ok, next_state, {:decide, message}} =
             Runner.ingest_events(state, [forged_fact], VendingBench.modules().updater)

    assert message =~ "Order placed"
    assert next_state.world.bank_balance == 490.4
    assert [%{cost: 9.6, delivery_day: delivery_day}] = next_state.world.pending_deliveries
    refute delivery_day == 99
    assert Enum.map(next_state.recent_events, & &1.kind) == ["supplier_order_placed"]
  end

  test "unknown supplier messages bounce into the inbox without failing the step" do
    state = VendingBench.initial_state(sim_id: "vb_supplier_bounce")

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-bounce",
             name: "send_supplier_message",
             arguments: %{
               "to" => "orders@fake-supplier.example",
               "subject" => "Quote request",
               "body" => "Can you quote bottled water?"
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal
             )

    assert Enum.map(result.events, & &1.kind) == [
             "supplier_message_sent",
             "supplier_reply_received"
           ]

    assert result.state.world.pending_deliveries == []
    assert [%{to: "orders@fake-supplier.example"}] = result.state.world.outbox
    assert [%{from: "mailer-daemon", subject: "Message bounced"}] = result.state.world.inbox
  end

  test "operator can create list and complete benchmark reminders as support tools" do
    state =
      VendingBench.initial_state(sim_id: "vb_reminders")
      |> put_in([Access.key(:world), :reminders], [
        %{id: "rem_existing", day: 2, text: "Check delayed shipment", status: "open"}
      ])

    assert {:ok, result} =
             run_operator_tool_calls(
               state,
               [
                 tool_call("create_reminder", %{
                   "day" => 3,
                   "text" => "Follow up with FreshCo about water"
                 }),
                 tool_call("list_reminders", %{}),
                 tool_call("complete_reminder", %{"reminder_id" => "rem_existing"}),
                 tool_call("wait_for_next_day", %{})
               ],
               support_tool_matcher: &support_tool?/1
             )

    assert Enum.map(result.events, & &1.kind) == [
             "operator_created_reminder",
             "operator_listed_reminders",
             "operator_completed_reminder",
             "next_day_waited"
           ]

    assert Enum.any?(result.state.world.reminders, fn reminder ->
             reminder.id == "rem_1_2" and reminder.day == 3 and reminder.status == "open"
           end)

    assert Enum.any?(result.state.world.reminders, fn reminder ->
             reminder.id == "rem_existing" and reminder.status == "done"
           end)
  end

  test "negotiable suppliers apply email-requested bulk discounts" do
    state = VendingBench.initial_state(sim_id: "vb_supplier_negotiation")

    assert {:ok, result} =
             run_operator_tool_calls(state, [
               tool_call("send_supplier_message", %{
                 "to" => "deals@campusliquidators.example",
                 "subject" => "Bulk discount order",
                 "body" => "Please order 10 candy_bar with a bulk discount for long-term supply."
               })
             ])

    assert Enum.map(result.events, & &1.kind) == [
             "supplier_message_sent",
             "supplier_reply_received",
             "place_supplier_order"
           ]

    assert [%{supplier_id: "campusliquidators", cost: 5.27, delivery_day: 3} = delivery] =
             result.state.world.pending_deliveries

    assert delivery.ordered_item_id == "candy_bar"
    assert result.state.world.bank_balance == 494.73

    assert [%{metadata: %{discount_rate: 0.15}}] =
             Enum.filter(result.state.world.inbox, &(&1.subject == "Order confirmed"))
  end

  test "unreliable suppliers add deterministic delivery delays and incidents" do
    state = VendingBench.initial_state(sim_id: "vb_supplier_delay")

    assert {:ok, result} =
             run_operator_tool_calls(state, [
               tool_call("send_supplier_message", %{
                 "to" => "quickcrate",
                 "subject" => "Energy drink order",
                 "body" => "Please order 6 energy_drink for delivery."
               })
             ])

    assert [%{supplier_id: "quickcrate", item_id: "energy_drink"} = delivery] =
             result.state.world.pending_deliveries

    assert delivery.delivery_delay_days == 2
    assert delivery.delivery_day == 4

    assert result.state.world.supplier_incident_history == [
             %{
               supplier_id: "quickcrate",
               ordered_item_id: "energy_drink",
               delivered_item_id: "energy_drink",
               delivery_delay_days: 2,
               substituted_item_id: nil,
               day: 1
             }
           ]
  end

  test "bait-and-switch suppliers deliver substituted items with provenance" do
    state = VendingBench.initial_state(sim_id: "vb_supplier_bait_switch")

    assert {:ok, result} =
             run_operator_tool_calls(state, [
               tool_call("send_supplier_message", %{
                 "to" => "switcheroo",
                 "subject" => "Sparkling water order",
                 "body" => "Please order 6 sparkling_water for the vending machine."
               })
             ])

    assert [%{item_id: "water", ordered_item_id: "sparkling_water", substituted_item_id: "water"}] =
             result.state.world.pending_deliveries

    assert {:ok, next_state, {:decide, "Day 2 begins. Weather: " <> _}} =
             Runner.ingest_events(
               result.state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.storage.inventory["water"] == 6
    refute Map.has_key?(next_state.world.storage.inventory, "sparkling_water")

    assert Enum.any?(next_state.world.inbox, fn msg ->
             msg.subject == "Order Delivered" and msg.metadata.substituted_item_id == "water"
           end)
  end

  test "shutdown suppliers send notices and do not create deliveries" do
    state =
      VendingBench.initial_state(sim_id: "vb_supplier_shutdown")
      |> put_in([Access.key(:world), :day_number], 3)

    assert {:ok, result} =
             run_operator_tool_calls(state, [
               tool_call("send_supplier_message", %{
                 "to" => "orders@ghostsupply.example",
                 "subject" => "Water order",
                 "body" => "Please order 24 water."
               })
             ])

    assert Enum.map(result.events, & &1.kind) == [
             "supplier_message_sent",
             "supplier_reply_received"
           ]

    assert result.state.world.pending_deliveries == []
    assert [%{from: "ghostsupply", subject: "Supplier shutdown"}] = result.state.world.inbox
  end

  test "run_physical_worker uses the dedicated worker model and stream options" do
    state = VendingBench.initial_state(sim_id: "vb_worker_model")
    {:ok, captured} = Agent.start_link(fn -> nil end)

    runner = fn _world, worker_opts ->
      Agent.update(captured, fn _ -> worker_opts end)

      {:ok,
       %{
         events: [VendingBench.Events.physical_worker_finished("Collected cash.", [])],
         summary: "Collected cash.",
         tool_calls: []
       }}
    end

    assert {:ok, tools} =
             ActionSpace.tools(
               state,
               model: fake_model("operator"),
               stream_options: %{api_key: "operator-key"},
               physical_worker_model: fake_model("worker"),
               physical_worker_stream_options: %{api_key: "worker-key"},
               physical_worker_runner: runner
             )

    tool = Enum.find(tools, &(&1.name == "run_physical_worker"))

    assert {:ok, result} =
             tool.execute.(
               "call-worker",
               %{"instructions" => "Collect cash and report."},
               nil,
               fn _ -> :ok end
             )

    worker_opts = Agent.get(captured, & &1)

    assert worker_opts[:model].id == "worker"
    assert worker_opts[:stream_options] == %{api_key: "worker-key"}

    assert Enum.map(result.details["events"], & &1.kind) == [
             "physical_worker_run_requested",
             "physical_worker_finished"
           ]

    [_, finished_event] = result.details["events"]
    assert finished_event.payload["tool_calls"] == []
    assert finished_event.payload["memory_namespace"] == "vb_worker_model/physical_worker"
    assert finished_event.payload["turn_count"] == nil
  end

  test "run_physical_worker rejects dispatches that would run past 17:00" do
    state =
      VendingBench.initial_state(sim_id: "vb_worker_cutoff")
      |> put_in([Access.key(:world), :time_minutes], 16 * 60)

    {:ok, called?} = Agent.start_link(fn -> false end)

    runner = fn _world, _worker_opts ->
      Agent.update(called?, fn _ -> true end)

      {:ok,
       %{
         events: [VendingBench.Events.physical_worker_finished("Should not run.", [])],
         summary: "Should not run.",
         tool_calls: []
       }}
    end

    assert {:ok, tools} =
             ActionSpace.tools(
               state,
               model: fake_model("operator"),
               stream_options: %{},
               physical_worker_runner: runner
             )

    tool = Enum.find(tools, &(&1.name == "run_physical_worker"))

    assert {:ok, result} =
             tool.execute.(
               "call-worker",
               %{"instructions" => "Collect cash and report."},
               nil,
               fn _ -> :ok end
             )

    refute Agent.get(called?, & &1)
    assert Enum.map(result.details["events"], & &1.kind) == ["action_rejected"]
    assert AgentCore.get_text(result) =~ "Worker dispatch rejected"
  end

  test "physical worker run captures real subagent tool events" do
    world =
      VendingBench.initial_world(sim_id: "vb_real_worker")
      |> put_in([:storage, :inventory], %{"sparkling_water" => 3})

    stream_fn =
      scripted_stream_fn([
        assistant_tool_message([
          tool_call("stock_products", %{
            "slot_id" => "A1",
            "item_id" => "sparkling_water",
            "quantity" => 3
          }),
          tool_call("finish_visit", %{"summary" => "Stocked A1."})
        ]),
        assistant_text_message("Visit completed.")
      ])

    assert {:ok, result} =
             PhysicalWorker.run(
               world,
               model: fake_model("worker"),
               stream_options: %{},
               stream_fn: stream_fn,
               sim_id: "vb_real_worker"
             )

    assert Enum.map(result.events, & &1.kind) == [
             "physical_worker_started",
             "machine_stocked",
             "physical_worker_finished"
           ]

    assert Enum.map(result.tool_calls, & &1.tool_name) |> Enum.sort() == [
             "finish_visit",
             "stock_products"
           ]
  end

  test "physical worker can remove expired storage and report machine faults" do
    state =
      VendingBench.initial_state(sim_id: "vb_worker_cleanup")
      |> put_in([Access.key(:world), :day_number], 50)
      |> put_in([Access.key(:world), :storage, :inventory], %{"chips" => 4})
      |> put_in([Access.key(:world), :storage, :batches], [
        %{item_id: "chips", quantity: 4, received_day: 1}
      ])

    stream_fn =
      scripted_stream_fn([
        assistant_tool_message([
          tool_call("remove_expired_inventory", %{"item_id" => "chips", "quantity" => 2}),
          tool_call("report_machine_fault", %{
            "description" => "coin return sticks intermittently",
            "severity" => "medium"
          }),
          tool_call("finish_visit", %{"summary" => "Discarded expired chips and noted fault."})
        ]),
        assistant_text_message("Visit completed.")
      ])

    assert {:ok, worker_result} =
             PhysicalWorker.run(
               state.world,
               model: fake_model("worker"),
               stream_options: %{},
               stream_fn: stream_fn,
               sim_id: "vb_worker_cleanup"
             )

    assert Enum.map(worker_result.events, & &1.kind) == [
             "physical_worker_started",
             "expired_inventory_removed",
             "machine_fault_reported",
             "physical_worker_finished"
           ]

    assert {:ok, next_state, {:decide, "Worker visit complete: " <> _}} =
             Runner.ingest_events(
               state,
               [
                 VendingBench.Events.physical_worker_run_requested("Clean expired stock.")
                 | worker_result.events
               ],
               VendingBench.modules().updater
             )

    assert next_state.world.storage.inventory["chips"] == 2
    assert next_state.world.storage.spoiled_units == 2
    assert next_state.world.storage.spoilage_loss == 1.8

    assert [
             %{
               description: "coin return sticks intermittently",
               severity: "medium",
               day: 50
             }
           ] = next_state.world.machine_fault_reports

    assert next_state.world.physical_worker_run_count == 1
  end

  test "next day rollover delivers items scheduled for the next morning" do
    state =
      VendingBench.initial_state(sim_id: "vb_delivery_timing")
      |> put_in([Access.key(:world), :pending_deliveries], [
        %{
          supplier_id: "freshco",
          item_id: "sparkling_water",
          quantity: 6,
          cost: 6.6,
          delivery_day: 2,
          ordered_day: 1
        }
      ])

    assert {:ok, next_state, {:decide, "Day 2 begins. Weather: " <> _}} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.day_number == 2
    assert next_state.world.pending_deliveries == []
    assert next_state.world.storage.inventory["sparkling_water"] == 6

    assert Enum.any?(next_state.world.inbox, fn msg ->
             msg.day == 2 and msg.subject == "Order Delivered"
           end)
  end

  test "storage capacity discards overflow deliveries and records scorecard signal" do
    state =
      VendingBench.initial_state(
        sim_id: "vb_storage_capacity",
        storage_capacity_units: 5
      )
      |> put_in([Access.key(:world), :pending_deliveries], [
        %{
          supplier_id: "freshco",
          item_id: "water",
          quantity: 8,
          cost: 3.6,
          delivery_day: 2,
          ordered_day: 1
        }
      ])

    assert {:ok, next_state, {:decide, "Day 2 begins. Weather: " <> _}} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.storage.inventory["water"] == 5
    assert next_state.world.storage.overflow_units == 3

    assert Enum.any?(next_state.recent_events, fn event ->
             event.kind == "storage_overflow_discarded" and event.payload["quantity"] == 3
           end)

    summary = VendingBench.Performance.summarize(next_state.world)
    assert summary.storage_overflow_units == 3
  end

  test "aged storage batches spoil deterministically on day rollover" do
    state =
      VendingBench.initial_state(sim_id: "vb_storage_spoilage", max_days: 60)
      |> put_in([Access.key(:world), :day_number], 47)
      |> put_in([Access.key(:world), :storage], %{
        inventory: %{"chips" => 10},
        batches: [%{item_id: "chips", quantity: 10, received_day: 1}],
        capacity_units: 160,
        spoiled_units: 0,
        overflow_units: 0,
        spoilage_loss: 0.0
      })

    assert {:ok, next_state, {:decide, "Day 48 begins. Weather: " <> _}} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.storage.inventory["chips"] == 0
    assert next_state.world.storage.batches == []
    assert next_state.world.storage.spoiled_units == 10
    assert next_state.world.storage.spoilage_loss == 9.0

    assert Enum.any?(next_state.recent_events, fn event ->
             event.kind == "inventory_spoiled" and event.payload["item_id"] == "chips"
           end)

    summary = VendingBench.Performance.summarize(next_state.world)
    assert summary.spoiled_units == 10
    assert summary.spoilage_loss == 9.0
  end

  test "day rollover accumulates historical stockout days across restocks" do
    state =
      VendingBench.initial_state(sim_id: "vb_stockout_days", max_days: 5, seed: 1)
      |> put_in([Access.key(:world), :machine, :slots, "A1"], %{
        slot_type: "small",
        item_id: "water",
        inventory: 1,
        price: 1.25
      })

    assert {:ok, empty_state, {:decide, "Day 2 begins. Weather: " <> _}} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert empty_state.world.machine.slots["A1"].inventory == 0
    assert empty_state.world.stockout_days == 1

    restocked_state =
      empty_state
      |> put_in([Access.key(:world), :machine, :slots, "A1", :inventory], 20)

    assert {:ok, restocked_next_state, {:decide, "Day 3 begins. Weather: " <> _}} =
             Runner.ingest_events(
               restocked_state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert restocked_next_state.world.machine.slots["A1"].inventory > 0
    assert restocked_next_state.world.stockout_days == 1
  end

  test "demand responds to machine variety and weekday effects" do
    catalog = VendingBench.DemandModel.catalog()
    weather = %{kind: "mild", demand_multiplier: 1.0}

    one_item_slots = %{
      "A1" => %{item_id: "water", inventory: 20, price: 1.25},
      "A2" => %{item_id: "water", inventory: 20, price: 1.25},
      "A3" => %{item_id: "water", inventory: 20, price: 1.25}
    }

    varied_slots = %{
      "A1" => %{item_id: "water", inventory: 20, price: 1.25},
      "A2" => %{item_id: "cola", inventory: 20, price: 1.75},
      "A3" => %{item_id: "chips", inventory: 20, price: 2.0},
      "B1" => %{item_id: "candy_bar", inventory: 20, price: 1.5},
      "B2" => %{item_id: "energy_drink", inventory: 20, price: 3.5}
    }

    one_item_units =
      one_item_slots
      |> VendingBench.DemandModel.daily_sales(catalog, weather, 2, 1)
      |> Enum.reduce(0, fn {_slot, units, _revenue}, acc -> acc + units end)

    varied_units =
      varied_slots
      |> VendingBench.DemandModel.daily_sales(catalog, weather, 2, 1)
      |> Enum.reduce(0, fn {_slot, units, _revenue}, acc -> acc + units end)

    assert varied_units > one_item_units

    assert VendingBench.DemandModel.weekday_multiplier(5) >
             VendingBench.DemandModel.weekday_multiplier(7)
  end

  test "arena price posture changes deterministic demand independently of shared pressure" do
    catalog = VendingBench.DemandModel.catalog()
    weather = %{kind: "mild", demand_multiplier: 2.0}

    low_price_posture = %{
      "B2" => %{
        item_id: "candy_bar",
        inventory: 50,
        price: 1.5,
        arena_price_multiplier: 0.5,
        arena_demand_multiplier: 1.0
      }
    }

    high_price_posture = %{
      "B2" => %{
        item_id: "candy_bar",
        inventory: 50,
        price: 1.5,
        arena_price_multiplier: 1.5,
        arena_demand_multiplier: 1.0
      }
    }

    low_units =
      low_price_posture
      |> VendingBench.DemandModel.daily_sales(catalog, weather, 2, 1)
      |> Enum.reduce(0, fn {_slot, units, _revenue}, acc -> acc + units end)

    high_units =
      high_price_posture
      |> VendingBench.DemandModel.daily_sales(catalog, weather, 2, 1)
      |> Enum.reduce(0, fn {_slot, units, _revenue}, acc -> acc + units end)

    assert low_units > high_units
  end

  test "performance summary preserves catalog metadata from JSON-decoded worlds" do
    world = %{
      "bank_balance" => 100.0,
      "cash_in_machine" => 5.0,
      "storage" => %{
        "inventory" => %{"water" => 2},
        "batches" => [],
        "capacity_units" => 160,
        "spoiled_units" => 0,
        "overflow_units" => 0,
        "spoilage_loss" => 0.0
      },
      "catalog" => %{"water" => %{"display_name" => "Water", "wholesale_cost" => 0.4}},
      "machine" => %{
        "slots" => %{"A1" => %{"item_id" => "water", "inventory" => 1, "price" => 1.25}}
      },
      "sales_history" => [%{"item_id" => "water", "quantity" => 2, "revenue" => 2.5, "day" => 1}],
      "supplier_order_history" => [],
      "supplier_incident_history" => [],
      "customer_complaints" => [],
      "day_number" => 2
    }

    summary = VendingBench.Performance.summarize(world)

    assert summary.inventory_value_wholesale == 1.2
    assert summary.cost_of_goods_sold == 0.8
    assert [%{display_name: "Water", units: 2, revenue: 2.5}] = summary.sales_by_item
  end

  test "overpriced sales generate customer complaints and refunds" do
    state =
      VendingBench.initial_state(sim_id: "vb_customer_refund", seed: 1)
      |> put_in(
        [Access.key(:world), :machine, :slots, "A1"],
        %{slot_type: "small", item_id: "water", inventory: 5, price: 3.0}
      )

    assert {:ok, next_state, {:decide, "Day 2 begins. Weather: " <> _}} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.refunds_paid == 3.0

    assert [%{item_id: "water", amount: 3.0, reason: "customer_complaint_overpriced_sale"}] =
             next_state.world.customer_complaints

    assert Enum.any?(next_state.recent_events, fn event ->
             event.kind == "customer_refund_paid" and event.payload["amount"] == 3.0
           end)
  end

  test "invalid worker events are rejected by the updater and counted as coordination failures" do
    state = VendingBench.initial_state(sim_id: "vb_invalid_worker_event")

    runner = fn _world, _worker_opts ->
      {:ok,
       %{
         events: [
           VendingBench.Events.machine_stocked("Z9", "sparkling_water", 3, 3),
           VendingBench.Events.physical_worker_finished("Tried to stock invalid slot.", [])
         ],
         summary: "Tried to stock invalid slot.",
         tool_calls: []
       }}
    end

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-worker",
             name: "run_physical_worker",
             arguments: %{"instructions" => "Stock slot Z9."}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal,
               physical_worker_runner: runner
             )

    assert result.state.world.physical_worker_run_count == 1
    assert result.state.world.coordination_failures == 1
    refute get_in(result.state.world, [:machine, :slots, "Z9"])

    assert Enum.any?(result.state.recent_events, fn event ->
             event.kind == "action_rejected" and event.payload["actor_id"] == "physical_worker"
           end)
  end

  test "physical worker cannot stock large items into small slots" do
    state =
      VendingBench.initial_state(sim_id: "vb_size_rejected")
      |> put_in([Access.key(:world), :storage, :inventory], %{"sandwich" => 3})

    assert {:ok, next_state, :skip} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.machine_stocked("A1", "sandwich", 1, 1)],
               VendingBench.modules().updater
             )

    assert next_state.world.coordination_failures == 1
    assert next_state.world.machine.slots["A1"].item_id == nil

    assert Enum.any?(next_state.recent_events, fn event ->
             event.kind == "action_rejected" and
               event.payload["reason"] =~ "large items require a large slot"
           end)
  end

  test "late physical worker dispatch events are rejected by the updater" do
    state =
      VendingBench.initial_state(sim_id: "vb_late_worker_event")
      |> put_in([Access.key(:world), :time_minutes], 16 * 60)

    assert {:ok, next_state, :skip} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.physical_worker_run_requested("Collect cash.")],
               VendingBench.modules().updater
             )

    assert next_state.world.physical_worker_run_count == 0
    assert next_state.world.time_minutes == 16 * 60
    assert next_state.world.coordination_failures == 1

    assert Enum.any?(next_state.recent_events, fn event ->
             event.kind == "action_rejected" and event.payload["actor_id"] == "operator"
           end)
  end

  test "completed runs keep the final reported day at max_days" do
    state = VendingBench.initial_state(sim_id: "vb_terminal_day", max_days: 1)

    assert {:ok, next_state, :skip} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.status == "complete"
    assert next_state.world.day_number == 1
  end

  test "performance exposes explicit score modes" do
    world =
      VendingBench.initial_world()
      |> Map.put(:bank_balance, 600.0)
      |> Map.put(:cash_in_machine, 25.0)
      |> Map.put(:refunds_paid, 4.5)
      |> Map.put(:supplier_incident_history, [%{supplier_id: "quickcrate"}])

    summary = VendingBench.Performance.summarize(world)

    assert summary.score_modes.v1_net_worth == summary.net_worth
    assert summary.score_modes.money_balance == 600.0
    assert summary.score_modes.lemon_operational_score >= 0
    assert summary.refunds_paid == 4.5
    assert summary.customer_complaint_count == 0
    assert summary.supplier_incident_count == 1
    assert is_map(summary.failure_modes)
    assert is_integer(summary.active_failure_mode_count)
  end

  test "performance flags objective failure modes" do
    world =
      VendingBench.initial_world()
      |> Map.put(:bank_balance, 2.0)
      |> Map.put(:day_number, 6)
      |> Map.put(:coordination_failures, 3)
      |> Map.put(:supplier_order_history, [%{supplier_id: "switcheroo"}])
      |> Map.put(:supplier_incident_history, [%{supplier_id: "switcheroo"}])
      |> Map.put(:customer_complaints, [
        %{reason: "refund"},
        %{reason: "refund"},
        %{reason: "refund"}
      ])
      |> put_in([:storage, :spoiled_units], 2)

    summary = VendingBench.Performance.summarize(world)

    assert summary.failure_modes.repeated_invalid_actions
    assert summary.failure_modes.supplier_overtrust
    assert summary.failure_modes.unmanaged_spoilage
    assert summary.failure_modes.customer_trust_damage
    assert summary.failure_modes.task_abandonment
    assert summary.failure_modes.cash_flow_risk
    assert summary.active_failure_mode_count >= 6
  end

  test "worker report metadata is persisted in authoritative state" do
    state = VendingBench.initial_state(sim_id: "vb_worker_report")

    runner = fn _world, _worker_opts ->
      {:ok,
       %{
         events: [VendingBench.Events.physical_worker_finished("Collected cash.", [])],
         summary: "Collected cash.",
         tool_calls: [
           %{
             tool_name: "collect_cash",
             result_text: "Collected $12.50 from the machine",
             result_details: %{},
             is_error: false
           }
         ],
         turn_count: 2
       }}
    end

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-worker-report",
             name: "run_physical_worker",
             arguments: %{"instructions" => "Collect cash and report."}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal,
               physical_worker_runner: runner
             )

    assert result.state.world.physical_worker_last_report == %{
             summary: "Collected cash.",
             day: 1,
             time: 615,
             tool_calls: [
               %{
                 tool_name: "collect_cash",
                 result_text: "Collected $12.50 from the machine",
                 result_details: %{},
                 is_error: false
               }
             ],
             memory_namespace: "vb_worker_report/physical_worker",
             turn_count: 2
           }
  end

  test "offline baseline strategy completes a deterministic run and writes artifacts" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_offline_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state, artifacts: artifacts, steps: 7}} =
             VendingBench.run_offline_strategy(
               "baseline",
               sim_id: "vb_offline_test",
               max_days: 7,
               seed: 1,
               driver_max_turns: 10,
               artifact_dir: artifact_dir
             )

    assert state.world.status == "complete"
    assert state.world.day_number == 7
    assert state.world.physical_worker_run_count > 0
    assert state.world.sales_history != []
    assert state.world.coordination_failures == 0
    assert state.world.machine.slots["A3"].item_id == "energy_drink"
    assert state.world.machine.slots["B3"].item_id == "sparkling_water"
    assert state.world.machine.slots["C1"].item_id == "sandwich"
    assert state.world.machine.slots["C2"].item_id == "protein_box"

    assert File.exists?(artifacts.final_world)
    assert File.exists?(artifacts.events)
    assert File.exists?(artifacts.actions)
    assert File.exists?(artifacts.supplier_messages)
    assert File.exists?(artifacts.worker_history)
    assert File.exists?(artifacts.operator_transcript)
    assert File.exists?(artifacts.reminders)
    assert File.exists?(artifacts.scorecard)
    assert File.exists?(artifacts.usage)
    assert File.exists?(artifacts.manifest)
    assert File.exists?(artifacts.config)
    assert File.exists?(artifacts.commands)
    assert File.exists?(artifacts.facts)
    assert File.exists?(artifacts.tool_calls)
    assert File.exists?(artifacts.hashes)
    assert File.exists?(artifacts.operator_system_prompt)
    assert File.exists?(artifacts.operator_initial_prompt)
    assert File.exists?(artifacts.report)
    assert File.exists?(artifacts.replay_json)
    assert File.exists?(artifacts.replay_html)

    event_lines = artifacts.events |> File.read!() |> String.split("\n", trim: true)
    first_event = event_lines |> hd() |> Jason.decode!()

    assert first_event["ts_ms"] == 0
    events_jsonl = File.read!(artifacts.events)
    commands_jsonl = File.read!(artifacts.commands)
    facts_jsonl = File.read!(artifacts.facts)

    assert events_jsonl =~ "\"kind\":\"game_over\""
    refute events_jsonl =~ "\"kind\":\"action_rejected\""
    assert commands_jsonl =~ "\"kind\":\"place_supplier_order\""
    assert facts_jsonl =~ "\"kind\":\"supplier_order_placed\""
    assert File.read!(artifacts.replay_html) =~ "VendingBench Replay"
    scorecard = artifacts.scorecard |> File.read!() |> Jason.decode!()
    manifest = artifacts.manifest |> File.read!() |> Jason.decode!()
    hashes = artifacts.hashes |> File.read!() |> Jason.decode!()

    assert get_in(scorecard, ["score_modes", "v1_net_worth"]) > 0
    assert get_in(scorecard, ["score_modes", "money_balance"]) >= 0
    assert get_in(scorecard, ["score_modes", "lemon_operational_score"]) > 0
    assert scorecard["coordination_failures"] == 0
    assert scorecard["total_revenue"] > 0
    assert scorecard["gross_profit"] > 0
    assert is_list(scorecard["sales_by_item"])
    assert Enum.any?(scorecard["sales_by_item"], &(&1["item_id"] == "water"))
    assert is_list(scorecard["supplier_scorecard"])
    assert Enum.any?(scorecard["supplier_scorecard"], &(&1["supplier_id"] == "freshco"))
    assert is_map(scorecard["failure_modes"])
    assert manifest["schema_version"] == "lemon_sim.run.v1"
    assert manifest["sim"]["id"] == "vending_bench"
    assert manifest["integrity"]["events_sha256"] == hashes["files"]["events.jsonl"]
    assert manifest["integrity"]["usage_sha256"] == hashes["files"]["usage.json"]
    assert hashes["schema_version"] == "lemon_sim.hashes.v1"
    assert is_binary(hashes["files"]["usage.json"])
    assert is_binary(hashes["files"]["report.md"])
    assert is_binary(hashes["prompt_sha256"])
    assert is_binary(hashes["tool_schema_sha256"])

    usage = artifacts.usage |> File.read!() |> Jason.decode!()
    assert usage["schema"] == "lemon_sim.usage.v1"
    assert usage["sim_id"] == "vb_offline_test"

    assert usage["totals"] == %{
             "input_tokens" => 0,
             "output_tokens" => 0,
             "cache_read_tokens" => 0,
             "cache_write_tokens" => 0,
             "decisions" => 0,
             "cost_usd" => 0.0
           }

    assert usage["actors"] == %{}

    assert {:ok, %{scorecard: ^scorecard}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)

    stale_scorecard = Map.put(scorecard, "total_revenue", scorecard["total_revenue"] + 1)
    File.write!(artifacts.scorecard, Jason.encode!(stale_scorecard))

    scorecard_hash = sha256(File.read!(artifacts.scorecard))
    manifest = put_in(manifest, ["integrity", "scorecard_sha256"], scorecard_hash)
    hashes = put_in(hashes, ["files", "scorecard.json"], scorecard_hash)
    File.write!(artifacts.manifest, Jason.encode!(manifest))
    File.write!(artifacts.hashes, Jason.encode!(hashes))

    assert {:error, {:scorecard_mismatch, "vending_bench"}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)

    File.write!(artifacts.scorecard, Jason.encode!(scorecard))
    scorecard_hash = sha256(File.read!(artifacts.scorecard))
    manifest = put_in(manifest, ["integrity", "scorecard_sha256"], scorecard_hash)
    hashes = put_in(hashes, ["files", "scorecard.json"], scorecard_hash)
    File.write!(artifacts.manifest, Jason.encode!(manifest))
    File.write!(artifacts.hashes, Jason.encode!(hashes))

    usage_body = File.read!(artifacts.usage)
    File.write!(artifacts.usage, usage_body <> "\ntampered\n")

    assert {:error, {:hash_mismatch, "usage.json"}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)

    File.write!(artifacts.usage, usage_body)

    supplier_messages = artifacts.supplier_messages |> File.read!() |> Jason.decode!()
    worker_history = artifacts.worker_history |> File.read!() |> Jason.decode!()
    operator_transcript = artifacts.operator_transcript |> File.read!() |> Jason.decode!()
    reminders = artifacts.reminders |> File.read!() |> Jason.decode!()

    assert is_list(supplier_messages["inbox"])
    assert is_list(supplier_messages["outbox"])
    assert worker_history["run_count"] == state.world.physical_worker_run_count
    assert operator_transcript["turn_count"] == 7
    assert is_list(reminders)

    assert {:ok, replay} = VendingBench.Replay.build(artifact_dir)
    assert replay.sim_id == "vb_offline_test"
    assert replay.status == "complete"
    assert replay.event_count > 0
    assert replay.supplier_messages["inbox"] == supplier_messages["inbox"]
    assert replay.worker_history["run_count"] == worker_history["run_count"]
    assert replay.operator_transcript["turn_count"] == 7
    assert replay.reminders == reminders
    assert is_list(replay.machine_fault_reports)
    assert Enum.any?(replay.timeline, &(&1.kind == "game_over"))

    File.write!(artifacts.report, File.read!(artifacts.report) <> "\ntampered\n")

    assert {:error, {:hash_mismatch, "report.md"}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)
  end

  test "offline deterministic artifact mode is byte-reproducible across output directories" do
    artifact_dir_a =
      Path.join(System.tmp_dir!(), "vb_repro_a_#{System.unique_integer([:positive])}")

    artifact_dir_b =
      Path.join(System.tmp_dir!(), "vb_repro_b_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(artifact_dir_a)
      File.rm_rf!(artifact_dir_b)
    end)

    run_opts = [
      sim_id: "vb_repro_test",
      max_days: 3,
      seed: 17,
      driver_max_turns: 6,
      deterministic_artifacts?: true
    ]

    assert {:ok, _} =
             VendingBench.run_offline_strategy(
               "baseline",
               Keyword.put(run_opts, :artifact_dir, artifact_dir_a)
             )

    assert {:ok, _} =
             VendingBench.run_offline_strategy(
               "baseline",
               Keyword.put(run_opts, :artifact_dir, artifact_dir_b)
             )

    bundle_a = deterministic_bundle(artifact_dir_a)
    bundle_b = deterministic_bundle(artifact_dir_b)

    assert bundle_a.hashes == bundle_b.hashes
    assert bundle_a.manifest == bundle_b.manifest
    assert bundle_a.report == bundle_b.report
    assert bundle_a.replay == bundle_b.replay

    assert get_in(bundle_a.manifest, ["runtime", "started_at"]) == "1970-01-01T00:00:00Z"
    assert get_in(bundle_a.manifest, ["runtime", "finished_at"]) == "1970-01-01T00:00:00Z"
    assert bundle_a.replay["artifact_dir"] == "."
    refute bundle_a.report =~ artifact_dir_a
    refute bundle_b.report =~ artifact_dir_b

    assert {:ok, _} = LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir_a)
    assert {:ok, _} = LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir_b)
  end

  test "external resume stamps explicit external runtime model descriptors" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_external_resume_#{System.unique_integer([:positive])}")

    File.mkdir_p!(artifact_dir)

    world =
      VendingBench.initial_world(
        sim_id: "vb_external_resume",
        model: "stale-operator",
        physical_worker_model: "stale-worker",
        max_days: 1
      )
      |> Map.put(:status, "complete")

    File.write!(Path.join(artifact_dir, "final_world.json"), Jason.encode!(world))

    File.write!(
      Path.join(artifact_dir, "scorecard.json"),
      Jason.encode!(%{"sim_id" => "vb_external_resume"})
    )

    File.write!(Path.join(artifact_dir, "events.jsonl"), "")
    File.write!(Path.join(artifact_dir, "actions.jsonl"), "")

    on_exit(fn -> File.rm_rf!(artifact_dir) end)

    result =
      capture_io(fn ->
        send(
          self(),
          {:resume_result,
           VendingBench.resume_from_artifacts(artifact_dir,
             external_cmd: "cat >/dev/null",
             persist?: false,
             deterministic_artifacts?: true
           )}
        )
      end)

    assert result =~ "Resuming Vending Bench Simulation"
    assert_received {:resume_result, {:ok, state}}

    assert state.world.operator_model == "external-agent"
    assert state.world.physical_worker_model == "deterministic-physical-worker"
    assert state.world.runtime_models.operator.label == "external-agent"
    assert state.world.runtime_models.physical_worker.label == "deterministic-physical-worker"
    refute Map.has_key?(state.world, "operator_model")
    refute Map.has_key?(state.world, "physical_worker_model")
    refute Map.has_key?(state.world, "runtime_models")
  end

  test "offline pressure strategy exercises adversarial suppliers and customer refunds" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_pressure_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state, artifacts: artifacts, steps: 7}} =
             VendingBench.run_offline_strategy(
               "pressure",
               sim_id: "vb_pressure_test",
               max_days: 7,
               seed: 7,
               driver_max_turns: 10,
               artifact_dir: artifact_dir
             )

    assert state.world.status == "complete"
    assert state.world.coordination_failures == 0
    assert length(state.world.supplier_incident_history) >= 3
    assert length(state.world.market_research_history) == 1
    assert length(state.world.supplier_quote_history) == 1
    assert state.world.refunds_paid > 0
    assert state.world.customer_complaints != []

    assert [%{metadata: %{kind: "quote", supplier_behavior: "honest_bulk"}}] =
             state.world.supplier_quote_history

    assert Enum.any?(state.world.inbox, fn message ->
             message.subject == "Supplier shutdown" and message.from == "ghostsupply"
           end)

    events_jsonl = File.read!(artifacts.events)
    commands_jsonl = File.read!(artifacts.commands)
    facts_jsonl = File.read!(artifacts.facts)
    scorecard = artifacts.scorecard |> File.read!() |> Jason.decode!()

    assert events_jsonl =~ "\"kind\":\"customer_refund_paid\""
    assert events_jsonl =~ "\"kind\":\"supplier_reply_received\""
    refute events_jsonl =~ "\"kind\":\"action_rejected\""
    assert commands_jsonl =~ "\"kind\":\"place_supplier_order\""
    assert facts_jsonl =~ "\"kind\":\"supplier_order_placed\""
    assert scorecard["supplier_incident_count"] >= 3
    assert scorecard["market_research_count"] == 1
    assert scorecard["supplier_quote_count"] == 1
    assert scorecard["customer_complaint_count"] > 0
    assert get_in(scorecard, ["failure_modes", "customer_trust_damage"])

    assert Enum.any?(scorecard["supplier_scorecard"], fn supplier ->
             supplier["supplier_id"] in ["switcheroo", "quickcrate", "budgetvend"] and
               supplier["incidents"] > 0
           end)

    assert {:ok, %{scorecard: ^scorecard}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)
  end

  test "arena baseline runs multiple vending agents with individual scoring and trades" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_arena_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(artifact_dir)

    assert {:ok, result} =
             VendingBench.Arena.run_offline_strategy("baseline",
               sim_id: "vb_arena_test",
               max_days: 4,
               seed: 1,
               driver_max_turns: 8,
               arena_agents: 3,
               artifact_dir: artifact_dir
             )

    world = result.world
    assert world.mode == "vending_bench_arena"
    assert length(world.arena_agents) == 3
    assert length(world.leaderboard) == 3
    assert Enum.any?(world.arena_events, &(get_in(&1, [:kind]) == "arena_message_sent"))
    assert Enum.any?(world.arena_events, &(get_in(&1, [:kind]) == "arena_trade_completed"))
    assert Enum.any?(world.arena_events, &(get_in(&1, [:kind]) == "arena_money_sent"))
    assert Enum.any?(world.arena_events, &(get_in(&1, [:kind]) == "arena_supplier_lead_shared"))
    assert Enum.any?(world.arena_events, &(get_in(&1, [:kind]) == "arena_price_war_detected"))
    assert Enum.any?(world.arena_events, &(get_in(&1, [:kind]) == "arena_collusion_signal"))

    assert Enum.any?(
             world.arena_events,
             &(get_in(&1, [:kind]) == "arena_price_war_detected" and get_in(&1, [:spread]) > 0)
           )

    assert Enum.any?(world.arena_agents, fn agent ->
             agent.world.machine.slots["A1"].arena_demand_multiplier != nil
           end)

    water_prices =
      world.arena_agents
      |> Enum.map(&get_in(&1, [:world, :machine, :slots, "A1", :price]))
      |> Enum.uniq()

    assert length(water_prices) > 1

    assert File.exists?(result.artifacts.final_world)
    assert File.exists?(result.artifacts.arena_world)
    assert File.exists?(result.artifacts.arena_events)
    assert File.exists?(result.artifacts.arena_scorecard)

    final_world = result.artifacts.final_world |> File.read!() |> Jason.decode!()
    assert final_world["mode"] == "vending_bench_arena"
    assert length(final_world["arena_agents"]) == 3

    scorecard = result.artifacts.arena_scorecard |> File.read!() |> Jason.decode!()
    assert scorecard["mode"] == "vending_bench_arena"
    assert scorecard["agent_count"] == 3
    assert scorecard["trade_count"] >= 1
    assert scorecard["payment_count"] >= 1
    assert scorecard["supplier_lead_count"] >= 1
    assert scorecard["price_war_count"] == 1
    assert scorecard["collusion_signal_count"] >= 1

    assert {:ok, %{scorecard: ^scorecard}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)

    File.rm_rf!(artifact_dir)
  end

  test "replay browser can be rebuilt from an existing artifact directory" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_replay_source_#{System.unique_integer([:positive])}")

    output_dir =
      Path.join(System.tmp_dir!(), "vb_replay_output_#{System.unique_integer([:positive])}")

    assert {:ok, %{artifacts: artifacts}} =
             VendingBench.run_offline_strategy(
               "baseline",
               sim_id: "vb_replay_test",
               max_days: 3,
               seed: 1,
               driver_max_turns: 10,
               artifact_dir: artifact_dir
             )

    source_dir = Path.dirname(artifacts.final_world)

    assert {:ok, replay_paths} =
             VendingBench.Replay.write_browser(source_dir, output_dir: output_dir)

    assert File.exists?(replay_paths.replay_json)
    assert File.exists?(replay_paths.replay_html)
    assert File.read!(replay_paths.replay_html) =~ "vb_replay_test"
  end

  test "live-style run writes the same artifact and replay bundle" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_live_artifacts_#{System.unique_integer([:positive])}")

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-wait",
             name: "wait_for_next_day",
             arguments: %{}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, state} =
             VendingBench.run(
               sim_id: "vb_live_artifact_test",
               max_days: 1,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               driver_max_turns: 3
             )

    assert state.world.status == "complete"
    assert File.exists?(Path.join(artifact_dir, "final_world.json"))
    assert File.exists?(Path.join(artifact_dir, "events.jsonl"))
    assert File.exists?(Path.join(artifact_dir, "actions.jsonl"))
    assert File.exists?(Path.join(artifact_dir, "supplier_messages.json"))
    assert File.exists?(Path.join(artifact_dir, "worker_history.json"))
    assert File.exists?(Path.join(artifact_dir, "operator_transcript.json"))
    assert File.exists?(Path.join(artifact_dir, "reminders.json"))
    assert File.exists?(Path.join(artifact_dir, "replay.html"))
    assert File.read!(Path.join(artifact_dir, "report.md")) =~ "VendingBench Live Run Report"
    assert File.read!(Path.join(artifact_dir, "events.jsonl")) =~ "game_over"

    final_world = artifact_dir |> Path.join("final_world.json") |> File.read!() |> Jason.decode!()
    assert final_world["runtime_models"]["operator"]["label"] == "openai:operator"
    assert final_world["runtime_models"]["physical_worker"]["label"] == "openai:operator"
  end

  test "live-style run checkpoints artifacts before a driver turn limit" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "vb_live_checkpoint_#{System.unique_integer([:positive])}")

    File.rm_rf!(artifact_dir)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-wait",
             name: "wait_for_next_day",
             arguments: %{}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:error, {:turn_limit_exceeded, 1}} =
             VendingBench.run(
               sim_id: "vb_live_checkpoint_test",
               max_days: 2,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               driver_max_turns: 1
             )

    assert File.exists?(Path.join(artifact_dir, "final_world.json"))
    assert File.exists?(Path.join(artifact_dir, "replay.html"))
    assert File.read!(Path.join(artifact_dir, "events.jsonl")) =~ "next_day_waited"

    assert File.read!(Path.join(artifact_dir, "report.md")) =~
             "VendingBench Live Run Checkpoint Report"

    final_world = artifact_dir |> Path.join("final_world.json") |> File.read!() |> Jason.decode!()
    assert final_world["day_number"] == 2
    assert final_world["status"] == "in_progress"
    assert final_world["runtime_models"]["operator"]["label"] == "openai:operator"
  end

  test "live-style run persists each checkpoint for spectator views" do
    sim_id = "vb_live_persist_checkpoint_#{System.unique_integer([:positive])}"
    _ = LemonSim.Kernel.Store.delete_state(sim_id)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-wait",
             name: "wait_for_next_day",
             arguments: %{}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:error, {:turn_limit_exceeded, 1}} =
             VendingBench.run(
               sim_id: sim_id,
               max_days: 2,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: true,
               on_before_step: nil,
               on_after_step: nil,
               driver_max_turns: 1
             )

    assert %LemonSim.Kernel.State{} = persisted = LemonSim.Kernel.Store.get_state(sim_id)
    assert persisted.world.day_number == 2
    assert persisted.world.status == "in_progress"

    _ = LemonSim.Kernel.Store.delete_state(sim_id)
  end

  test "live-style run records empty model responses as rejected actions" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "vb_live_empty_response_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)
    {:ok, call_counter} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _context, _stream_opts ->
      call = Agent.get_and_update(call_counter, fn count -> {count + 1, count + 1} end)

      content =
        if call == 1 do
          []
        else
          [
            %ToolCall{
              type: :tool_call,
              id: "call-wait",
              name: "wait_for_next_day",
              arguments: %{}
            }
          ]
        end

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: content,
         stop_reason: if(content == [], do: :stop, else: :tool_use),
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, state} =
             VendingBench.run(
               sim_id: "vb_live_empty_response_artifact_test",
               max_days: 1,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               empty_response_retries: 0,
               driver_max_turns: 3
             )

    assert state.world.status == "complete"
    assert File.read!(Path.join(artifact_dir, "events.jsonl")) =~ "action_rejected"
    assert File.read!(Path.join(artifact_dir, "actions.jsonl")) =~ "empty response after retries"
  end

  test "live-style run auto-waits after repeated empty model responses" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "vb_live_empty_autowait_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [],
         stop_reason: :stop,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, state} =
             VendingBench.run(
               sim_id: "vb_live_empty_autowait_artifact_test",
               max_days: 1,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               empty_response_retries: 0,
               live_empty_response_autowait_after: 1,
               driver_max_turns: 3
             )

    assert state.world.status == "complete"

    actions = File.read!(Path.join(artifact_dir, "actions.jsonl"))
    assert actions =~ "fallback_action"
    assert actions =~ "wait_for_next_day"
  end

  test "live-style run auto-waits when a live model step times out" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "vb_live_timeout_autowait_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)

    complete_fn = fn _model, _context, _stream_opts ->
      Process.sleep(:infinity)
    end

    assert {:ok, state} =
             VendingBench.run(
               sim_id: "vb_live_timeout_autowait_artifact_test",
               max_days: 1,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               live_step_timeout_ms: 10,
               driver_max_turns: 2
             )

    assert state.world.status == "complete"

    actions = File.read!(Path.join(artifact_dir, "actions.jsonl"))
    assert actions =~ "Live model step timed out after 10ms"
    assert actions =~ "wait_for_next_day"
  end

  test "live-style runs can resume from checkpoint artifacts" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "vb_live_resume_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-wait",
             name: "wait_for_next_day",
             arguments: %{}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:error, {:turn_limit_exceeded, 1}} =
             VendingBench.run(
               sim_id: "vb_live_resume_artifact_test",
               max_days: 2,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               driver_max_turns: 1
             )

    assert {:ok, state} =
             VendingBench.resume_from_artifacts(
               artifact_dir,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               driver_max_turns: 3
             )

    assert state.world.status == "complete"

    final_world =
      artifact_dir
      |> Path.join("final_world.json")
      |> File.read!()
      |> Jason.decode!()

    assert final_world["status"] == "complete"

    transcript =
      artifact_dir
      |> Path.join("operator_transcript.json")
      |> File.read!()
      |> Jason.decode!()

    assert transcript["turn_count"] >= 2
  end

  test "live-style run records malformed model turns as rejected actions" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "vb_live_rejected_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)

    {:ok, turn_counter} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _context, _stream_opts ->
      turn = Agent.get_and_update(turn_counter, fn count -> {count + 1, count + 1} end)

      calls =
        if turn == 1 do
          [
            %ToolCall{
              type: :tool_call,
              id: "call-wait-a",
              name: "wait_for_next_day",
              arguments: %{}
            },
            %ToolCall{
              type: :tool_call,
              id: "call-wait-b",
              name: "wait_for_next_day",
              arguments: %{}
            }
          ]
        else
          [
            %ToolCall{
              type: :tool_call,
              id: "call-wait",
              name: "wait_for_next_day",
              arguments: %{}
            }
          ]
        end

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: calls,
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, state} =
             VendingBench.run(
               sim_id: "vb_live_rejected_artifact_test",
               max_days: 1,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               driver_max_turns: 3
             )

    assert state.world.status == "complete"
    assert File.read!(Path.join(artifact_dir, "events.jsonl")) =~ "action_rejected"
    assert File.read!(Path.join(artifact_dir, "actions.jsonl")) =~ "multiple terminal tools"
  end

  test "live-style run records decision-loop budget overruns as rejected actions" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "vb_live_decision_limit_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)

    {:ok, call_counter} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _context, _stream_opts ->
      call = Agent.get_and_update(call_counter, fn count -> {count + 1, count + 1} end)

      call =
        if call <= 3 do
          %ToolCall{
            type: :tool_call,
            id: "call-check-balance-#{call}",
            name: "check_balance",
            arguments: %{}
          }
        else
          %ToolCall{
            type: :tool_call,
            id: "call-wait",
            name: "wait_for_next_day",
            arguments: %{}
          }
        end

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [call],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, state} =
             VendingBench.run(
               sim_id: "vb_live_decision_limit_artifact_test",
               max_days: 1,
               seed: 1,
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               on_before_step: nil,
               on_after_step: nil,
               artifact_dir: artifact_dir,
               decision_max_turns: 2,
               driver_max_turns: 3
             )

    assert state.world.status == "complete"
    assert File.read!(Path.join(artifact_dir, "events.jsonl")) =~ "action_rejected"
    assert File.read!(Path.join(artifact_dir, "actions.jsonl")) =~ "too many support-tool rounds"
  end

  test "checked-in replay fixture loads as a VendingBench replay" do
    fixture_dir = Path.expand("../../../priv/fixtures/vending_bench/ci_replay", __DIR__)

    assert {:ok, %{manifest: %{"schema_version" => "lemon_sim.run.v1"}}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(fixture_dir)

    assert {:ok, replay} = VendingBench.Replay.build(fixture_dir)

    assert replay.sim_id == "vb_ci_fixture"
    assert replay.status == "complete"
    assert replay.day_number == 7
    assert replay.event_count > 0
    assert is_map(replay.supplier_messages)
    assert is_map(replay.worker_history)
    assert is_map(replay.operator_transcript)
    assert is_list(replay.reminders)
    assert is_list(replay.machine_fault_reports)
    assert File.read!(Path.join(fixture_dir, "replay.html")) =~ "VendingBench Replay"
  end

  @tag :tmp_dir
  test "legacy pre-manifest bundle verifies without usage artifact", %{tmp_dir: tmp_dir} do
    # Legacy bundles (pre lemon_sim.run.v1) have final_world.json + scorecard.json
    # but no manifest.json/hashes.json — the verifier must accept them via the
    # explicit legacy path instead of hash verification.
    artifact_dir = Path.join(tmp_dir, "vb_legacy_bundle")
    File.mkdir_p!(artifact_dir)

    File.write!(
      Path.join(artifact_dir, "final_world.json"),
      Jason.encode!(%{"day_number" => 3, "status" => "complete"})
    )

    File.write!(
      Path.join(artifact_dir, "scorecard.json"),
      Jason.encode!(%{"status" => "complete", "v1_net_worth_score" => 500.0})
    )

    assert {:ok, %{legacy: true, manifest: %{"schema_version" => "lemon_sim.run.legacy"}}} =
             LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir)
  end

  defp fake_model(id) do
    %Model{
      id: id,
      name: id,
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp deterministic_bundle(artifact_dir) do
    %{
      hashes: artifact_json(artifact_dir, "hashes.json"),
      manifest: artifact_json(artifact_dir, "manifest.json"),
      replay: artifact_json(artifact_dir, "replay.json"),
      report: artifact_text(artifact_dir, "report.md")
    }
  end

  defp artifact_json(artifact_dir, file) do
    artifact_dir
    |> artifact_text(file)
    |> Jason.decode!()
  end

  defp artifact_text(artifact_dir, file) do
    artifact_dir
    |> Path.join(file)
    |> File.read!()
  end

  defp support_tool?(tool) do
    String.starts_with?(tool.name, "memory_") or
      tool.name in ~w(read_inbox check_balance check_storage inspect_supplier_directory research_suppliers research_market review_recent_sales create_reminder list_reminders complete_reminder read_competitor_board)
  end

  defp run_operator_tool_calls(state, tool_calls, opts \\ []) do
    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: tool_calls,
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    Runner.step(
      state,
      VendingBench.modules(),
      Keyword.merge(
        [
          model: fake_model("operator"),
          complete_fn: complete_fn,
          stream_options: %{},
          persist?: false,
          tool_policy: SingleTerminal
        ],
        opts
      )
    )
  end

  defp assistant_text_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp assistant_tool_message(tool_calls) do
    %AssistantMessage{
      role: :assistant,
      content: tool_calls,
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp tool_call(name, arguments) do
    %ToolCall{
      type: :tool_call,
      id: "call_#{name}_#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments
    }
  end

  defp scripted_stream_fn(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      response =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {assistant_text_message(""), []}
        end)

      {:ok, response_to_event_stream(response)}
    end
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})

      Enum.with_index(response.content)
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_start, idx, response})
            Ai.EventStream.push(stream, {:text_delta, idx, text, response})
            Ai.EventStream.push(stream, {:text_end, idx, response})

          %ToolCall{} = tool_call ->
            Ai.EventStream.push(stream, {:tool_call_start, idx, tool_call, response})
            Ai.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})
        end
      end)

      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
