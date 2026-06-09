defmodule LemonSim.Examples.VendingBench.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.Kernel.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.VendingBench.{Events, PhysicalWorker, Suppliers}
  alias LemonSim.Examples.Helpers.Tools, as: GameTools
  alias LemonSim.LLM.Memory.Tools, as: MemoryTools

  @worker_visit_minutes 75
  @worker_latest_departure_minutes 17 * 60 - @worker_visit_minutes

  @impl true
  def tools(state, opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)

    if status != "in_progress" do
      {:ok, []}
    else
      sim_id = state.sim_id
      support = build_support_tools(world)
      memory = MemoryTools.build(sim_id: "#{sim_id}/operator")
      terminal = build_terminal_tools(world, state, opts)

      all_tools = Enum.map(support ++ memory ++ terminal, &GameTools.add_thought_param/1)
      {:ok, all_tools}
    end
  end

  # -- Support Tools --

  defp build_support_tools(world) do
    [
      read_inbox_tool(world),
      check_balance_tool(world),
      check_storage_tool(world),
      inspect_supplier_directory_tool(),
      research_suppliers_tool(),
      review_recent_sales_tool(world),
      create_reminder_tool(world),
      list_reminders_tool(world),
      complete_reminder_tool(world)
    ]
  end

  defp read_inbox_tool(world) do
    inbox = get(world, :inbox, [])

    %AgentTool{
      name: "read_inbox",
      description: "Read your inbox messages. You have #{length(inbox)} message(s).",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Read Inbox",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        text =
          if inbox == [] do
            "Inbox is empty."
          else
            inbox
            |> Enum.with_index(1)
            |> Enum.map(fn {msg, i} ->
              from = get(msg, :from, "unknown")
              subject = get(msg, :subject, "")
              body = get(msg, :body, "")
              "#{i}. From: #{from}\n   Subject: #{subject}\n   #{body}"
            end)
            |> Enum.join("\n\n")
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_read_inbox(length(inbox))},
           trust: :trusted
         }}
      end
    }
  end

  defp check_balance_tool(world) do
    balance = get(world, :bank_balance, 0.0)
    cash_in_machine = get(world, :cash_in_machine, 0.0)

    %AgentTool{
      name: "check_balance",
      description: "Check your financial status.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Check Balance",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        daily_fee = get(world, :daily_fee, 2.0)
        pending = get(world, :pending_deliveries, [])
        pending_cost = Enum.reduce(pending, 0.0, fn d, acc -> acc + get(d, :cost, 0.0) end)

        text = """
        Bank Balance: $#{format_price(balance)}
        Cash in Machine: $#{format_price(cash_in_machine)}
        Daily Operating Fee: $#{format_price(daily_fee)}
        Pending Delivery Costs: $#{format_price(pending_cost)}
        Net Worth: $#{format_price(balance + cash_in_machine)}
        """

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_checked_balance(balance)},
           trust: :trusted
         }}
      end
    }
  end

  defp check_storage_tool(world) do
    storage = get(world, :storage, %{})
    storage_inv = get(storage, :inventory, %{})
    catalog = get(world, :catalog, %{})
    capacity = get(storage, :capacity_units, 160)
    used = Enum.reduce(storage_inv, 0, fn {_item_id, qty}, acc -> acc + qty end)

    %AgentTool{
      name: "check_storage",
      description: "Check your storage warehouse inventory.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Check Storage",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        text =
          if map_size(storage_inv) == 0 do
            "Storage is empty. Capacity: #{used}/#{capacity} units. Order from suppliers to fill it."
          else
            lines =
              storage_inv
              |> Enum.sort_by(fn {id, _} -> id end)
              |> Enum.map(fn {item_id, qty} ->
                item_info = Map.get(catalog, item_id, %{})
                name = Map.get(item_info, :display_name, item_id)
                cost = Map.get(item_info, :wholesale_cost, 0.0)
                "  #{name} (#{item_id}): #{qty} units (wholesale: $#{format_price(cost)})"
              end)
              |> Enum.join("\n")

            "Storage Inventory (#{used}/#{capacity} units):\n#{lines}"
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_checked_storage(storage_inv)},
           trust: :trusted
         }}
      end
    }
  end

  defp inspect_supplier_directory_tool do
    %AgentTool{
      name: "inspect_supplier_directory",
      description:
        "View the supplier directory with available items, prices, and delivery times.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Inspect Suppliers",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        text = Suppliers.directory_text()
        directory = Suppliers.directory()

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_inspected_suppliers(map_size(directory))},
           trust: :trusted
         }}
      end
    }
  end

  defp review_recent_sales_tool(world) do
    recent_sales = get(world, :recent_sales, [])

    %AgentTool{
      name: "review_recent_sales",
      description: "Review recent sales data.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Review Sales",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        text =
          if recent_sales == [] do
            "No recent sales recorded yet."
          else
            lines =
              recent_sales
              |> Enum.take(-20)
              |> Enum.map(fn sale ->
                item = get(sale, :item_id, "?")
                qty = get(sale, :quantity, 0)
                rev = get(sale, :revenue, 0.0)
                day = get(sale, :day, "?")
                slot = get(sale, :slot_id, "?")
                "  Day #{day} | Slot #{slot}: #{qty}x #{item} — $#{format_price(rev)}"
              end)
              |> Enum.join("\n")

            "Recent Sales (last 20):\n#{lines}"
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_reviewed_sales(length(recent_sales))},
           trust: :trusted
         }}
      end
    }
  end

  defp research_suppliers_tool do
    %AgentTool{
      name: "research_suppliers",
      description:
        "Search the deterministic offline supplier research corpus for supplier discovery, pricing, and product fit.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Search query, for example beverage suppliers or snack pricing"
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      },
      label: "Research Suppliers",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        query = Map.get(params, "query", "")
        results = Suppliers.research(query)

        text =
          if results == [] do
            "No supplier research results found for #{inspect(query)}."
          else
            results
            |> Enum.with_index(1)
            |> Enum.map(fn {result, index} ->
              "#{index}. #{result.title}\n   #{result.body}"
            end)
            |> Enum.join("\n\n")
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_researched_suppliers(query, length(results))},
           trust: :trusted
         }}
      end
    }
  end

  defp create_reminder_tool(world) do
    %AgentTool{
      name: "create_reminder",
      description:
        "Create a benchmark-native reminder for a future simulated day, such as restock follow-up or delayed delivery check.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "day" => %{
            "type" => "integer",
            "description" => "Simulated day when the reminder should become due"
          },
          "text" => %{
            "type" => "string",
            "description" => "Reminder text"
          }
        },
        "required" => ["day", "text"],
        "additionalProperties" => false
      },
      label: "Create Reminder",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        day = Map.get(params, "day", get(world, :day_number, 1))
        text = params |> Map.get("text", "") |> to_string() |> String.trim()

        reminder_id =
          "rem_#{get(world, :day_number, 1)}_#{length(get(world, :reminders, [])) + 1}"

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("Created reminder #{reminder_id} for day #{day}: #{text}")
           ],
           details: %{"event" => Events.operator_created_reminder(reminder_id, day, text)},
           trust: :trusted
         }}
      end
    }
  end

  defp list_reminders_tool(world) do
    reminders = get(world, :reminders, [])

    %AgentTool{
      name: "list_reminders",
      description: "List open benchmark reminders.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "List Reminders",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        open_reminders = Enum.reject(reminders, &(get(&1, :status, "open") == "done"))

        text =
          if open_reminders == [] do
            "No open reminders."
          else
            open_reminders
            |> Enum.sort_by(fn reminder -> {get(reminder, :day, 0), get(reminder, :id, "")} end)
            |> Enum.map(fn reminder ->
              "#{get(reminder, :id, "?")} | day #{get(reminder, :day, "?")}: #{get(reminder, :text, "")}"
            end)
            |> Enum.join("\n")
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => Events.operator_listed_reminders(length(open_reminders))},
           trust: :trusted
         }}
      end
    }
  end

  defp complete_reminder_tool(world) do
    %AgentTool{
      name: "complete_reminder",
      description: "Mark an existing reminder complete by id.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "reminder_id" => %{"type" => "string", "description" => "Reminder id to complete"}
        },
        "required" => ["reminder_id"],
        "additionalProperties" => false
      },
      label: "Complete Reminder",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        reminder_id = Map.get(params, "reminder_id", "")
        reminders = get(world, :reminders, [])

        event =
          if Enum.any?(reminders, &(get(&1, :id, nil) == reminder_id)) do
            Events.operator_completed_reminder(reminder_id)
          else
            Events.action_rejected("operator", "Unknown reminder #{reminder_id}")
          end

        text =
          if event.kind == "action_rejected" do
            "Reminder #{reminder_id} was not found."
          else
            "Marked reminder #{reminder_id} complete."
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Terminal Tools --

  defp build_terminal_tools(world, state, opts) do
    [
      send_supplier_message_tool(world),
      send_supplier_email_tool(world),
      run_physical_worker_tool(world, state, opts),
      wait_for_next_day_tool()
    ]
  end

  defp send_supplier_message_tool(world) do
    %AgentTool{
      name: "send_supplier_message",
      description:
        "Send an email-style message to a supplier by id or email address. Use this for quotes, negotiation, and order requests discovered through research.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to" => %{
            "type" => "string",
            "description" =>
              "Supplier id or email address, for example freshco or orders@freshco.example"
          },
          "subject" => %{"type" => "string", "description" => "Email subject"},
          "body" => %{
            "type" => "string",
            "description" => "Email body. Order requests can say, for example, order 24 water."
          }
        },
        "required" => ["to", "subject", "body"],
        "additionalProperties" => false
      },
      label: "Email Supplier",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        to = Map.get(params, "to", "")
        subject = Map.get(params, "subject", "")
        body = Map.get(params, "body", "")
        current_day = get(world, :day_number, 1)
        balance = get(world, :bank_balance, 0.0)
        sent_event = Events.supplier_message_sent(to, subject, body)

        case Suppliers.process_message(to, subject, body, current_day) do
          {:ok, reply} ->
            reply_event =
              Events.supplier_reply_received(
                reply.supplier_id,
                reply.message,
                reply.metadata
              )

            order_event =
              if Map.get(reply.metadata, :kind) == "order_confirmed" and reply.cost <= balance do
                [
                  Events.place_supplier_order(
                    "operator",
                    reply.supplier_id,
                    reply.item_id,
                    reply.quantity,
                    "supplier_message:#{reply.supplier_id}:#{reply.item_id}:#{current_day}",
                    %{"negotiated" => Map.get(reply.metadata, :discount_rate, 0.0) > 0.0}
                  )
                ]
              else
                []
              end

            insufficient_events =
              if Map.get(reply.metadata, :kind) == "order_confirmed" and reply.cost > balance do
                [
                  Events.action_rejected(
                    "operator",
                    "Insufficient funds. Order costs $#{format_price(reply.cost)} but balance is $#{format_price(balance)}."
                  )
                ]
              else
                []
              end

            {:ok,
             %AgentToolResult{
               content: [AgentCore.text_content(reply.message)],
               details: %{
                 "events" => [sent_event, reply_event] ++ insufficient_events ++ order_event
               },
               trust: :trusted
             }}

          {:error, reply} ->
            reply_event =
              Events.supplier_reply_received(
                reply.supplier_id,
                reply.message,
                reply.metadata
              )

            {:ok,
             %AgentToolResult{
               content: [AgentCore.text_content(reply.message)],
               details: %{"events" => [sent_event, reply_event]},
               trust: :trusted
             }}
        end
      end
    }
  end

  defp send_supplier_email_tool(world) do
    supplier_ids = Suppliers.directory() |> Map.keys() |> Enum.sort()

    %AgentTool{
      name: "send_supplier_email",
      description:
        "Place an order with a supplier. Available suppliers: #{Enum.join(supplier_ids, ", ")}. " <>
          "Check the supplier directory first for items and minimum orders.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "supplier_id" => %{
            "type" => "string",
            "description" => "Supplier ID (e.g. freshco, snackworld, drinkdepot)"
          },
          "item_id" => %{
            "type" => "string",
            "description" => "Item to order (e.g. sparkling_water, chips)"
          },
          "quantity" => %{
            "type" => "integer",
            "description" => "Number of units to order"
          }
        },
        "required" => ["supplier_id", "item_id", "quantity"],
        "additionalProperties" => false
      },
      label: "Order from Supplier",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        supplier_id = Map.get(params, "supplier_id", "")
        item_id = Map.get(params, "item_id", "")
        quantity = Map.get(params, "quantity", 0)
        current_day = get(world, :day_number, 1)
        balance = get(world, :bank_balance, 0.0)

        case Suppliers.process_order(supplier_id, item_id, quantity, current_day) do
          {:ok, %{cost: cost, delivery_day: delivery_day}} ->
            if cost > balance do
              reason =
                "Insufficient funds. Order costs $#{format_price(cost)} but you only have $#{format_price(balance)}."

              {:ok,
               %AgentToolResult{
                 content: [AgentCore.text_content("Error: " <> reason)],
                 details: %{"events" => [Events.action_rejected("operator", reason)]},
                 trust: :trusted
               }}
            else
              event =
                Events.place_supplier_order(
                  "operator",
                  supplier_id,
                  item_id,
                  quantity,
                  "supplier_email:#{supplier_id}:#{item_id}:#{current_day}"
                )

              {:ok,
               %AgentToolResult{
                 content: [
                   AgentCore.text_content(
                     "Order placed with #{supplier_id}: #{quantity}x #{item_id} for $#{format_price(cost)}. Delivery on day #{delivery_day}."
                   )
                 ],
                 details: %{"event" => event},
                 trust: :trusted
               }}
            end

          {:error, reason} ->
            {:ok,
             %AgentToolResult{
               content: [AgentCore.text_content("Order failed: #{reason}")],
               details: %{"events" => [Events.action_rejected("operator", reason)]},
               trust: :trusted
             }}
        end
      end
    }
  end

  defp run_physical_worker_tool(world, state, opts) do
    worker_count = get(world, :physical_worker_run_count, 0)
    time_minutes = get(world, :time_minutes, 0)

    %AgentTool{
      name: "run_physical_worker",
      description:
        "Dispatch your physical worker to the vending machine with instructions. " <>
          "The worker can stock products, collect cash, set prices, and inspect the machine. " <>
          "Worker trips so far: #{worker_count}. Each trip takes ~75 minutes of sim time. " <>
          "Do not dispatch later than #{format_time(@worker_latest_departure_minutes)} so the worker is back by 17:00.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "instructions" => %{
            "type" => "string",
            "description" =>
              "Detailed instructions for the worker. Be specific about what to stock, what prices to set, etc."
          }
        },
        "required" => ["instructions"],
        "additionalProperties" => false
      },
      label: "Run Worker",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        instructions = Map.get(params, "instructions", "Inspect the machine.")
        worker_runner = Keyword.get(opts, :physical_worker_runner, &PhysicalWorker.run/2)

        if time_minutes > @worker_latest_departure_minutes do
          reason =
            "Too late to dispatch the physical worker at #{format_time(time_minutes)}. " <>
              "Worker visits must start by #{format_time(@worker_latest_departure_minutes)} to be back by 17:00."

          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content("Worker dispatch rejected: " <> reason)],
             details: %{"events" => [Events.action_rejected("operator", reason)]},
             trust: :trusted
           }}
        else
          worker_opts = [
            instructions: instructions,
            model: Keyword.get(opts, :physical_worker_model, Keyword.get(opts, :model)),
            stream_options:
              Keyword.get(
                opts,
                :physical_worker_stream_options,
                Keyword.get(opts, :stream_options, %{})
              ),
            stream_fn: Keyword.get(opts, :physical_worker_stream_fn),
            sim_id: state.sim_id,
            worker_timeout_ms: Keyword.get(opts, :physical_worker_timeout_ms, 30_000)
          ]

          case worker_runner.(world, worker_opts) do
            {:ok, result} ->
              request_event = Events.physical_worker_run_requested(instructions)

              worker_report = %{
                "summary" => result.summary,
                "tool_calls" => result.tool_calls,
                "memory_namespace" => "#{state.sim_id}/physical_worker",
                "turn_count" => Map.get(result, :turn_count)
              }

              all_events = [request_event | attach_worker_report(result.events, worker_report)]

              {:ok,
               %AgentToolResult{
                 content: [AgentCore.text_content("Worker visit complete: #{result.summary}")],
                 details: %{
                   "events" => all_events,
                   "worker_report" => worker_report
                 },
                 trust: :trusted
               }}

            {:error, reason} ->
              reason_text =
                case reason do
                  {:worker_failed, inner} -> inspect(inner)
                  other -> inspect(other)
                end

              {:ok,
               %AgentToolResult{
                 content: [AgentCore.text_content("Worker visit failed: #{reason_text}")],
                 details: %{
                   "events" => [Events.action_rejected("physical_worker", reason_text)]
                 },
                 trust: :trusted
               }}
          end
        end
      end
    }
  end

  defp wait_for_next_day_tool do
    %AgentTool{
      name: "wait_for_next_day",
      description:
        "End your day and wait for the next morning. " <>
          "Sales will be resolved, deliveries arrive, and daily fees are charged overnight.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Wait for Next Day",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.next_day_waited()

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Waiting for next day...")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Helpers --

  defp format_price(nil), do: "0.00"

  defp format_price(price) when is_float(price),
    do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp format_time(minutes) when is_integer(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}:#{String.pad_leading(to_string(mins), 2, "0")}"
  end

  defp attach_worker_report(events, worker_report) do
    Enum.map(events, fn event ->
      case event do
        %{kind: "physical_worker_finished", payload: payload} ->
          Events.physical_worker_finished(
            Map.get(payload, "summary", Map.get(payload, :summary, worker_report["summary"])),
            worker_report["tool_calls"],
            %{
              "memory_namespace" => worker_report["memory_namespace"],
              "turn_count" => worker_report["turn_count"]
            }
          )

        %{"kind" => "physical_worker_finished", "payload" => payload} ->
          Events.physical_worker_finished(
            Map.get(payload, "summary", Map.get(payload, :summary, worker_report["summary"])),
            worker_report["tool_calls"],
            %{
              "memory_namespace" => worker_report["memory_namespace"],
              "turn_count" => worker_report["turn_count"]
            }
          )

        other ->
          other
      end
    end)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
