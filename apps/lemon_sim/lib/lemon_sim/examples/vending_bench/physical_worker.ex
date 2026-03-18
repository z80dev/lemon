defmodule LemonSim.Examples.VendingBench.PhysicalWorker do
  @moduledoc """
  Supervised nested-agent runtime for the physical worker.

  The worker runs as a real `AgentCore` child under `AgentCore.SubagentSupervisor`
  with its own tool loop, memory namespace, and model options. The worker only
  mutates a local visit snapshot; authoritative sim state is still updated later
  by the Vending Bench updater from emitted events.
  """

  alias AgentCore.SubagentSupervisor
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.StreamOptions
  alias LemonSim.Examples.VendingBench.Events
  alias LemonSim.Memory.Tools, as: MemoryTools

  @worker_max_turns 5
  @default_timeout_ms 30_000

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(world, opts \\ []) do
    instructions = Keyword.get(opts, :instructions, "Inspect the machine and report status.")
    model = Keyword.fetch!(opts, :model)
    stream_options = normalize_stream_options(Keyword.get(opts, :stream_options, %{}))
    sim_id = Keyword.get(opts, :sim_id, "default")
    stream_fn = Keyword.get(opts, :stream_fn)
    timeout_ms = Keyword.get(opts, :worker_timeout_ms, @default_timeout_ms)

    {:ok, local_state} = Agent.start_link(fn -> build_local_snapshot(world) end)

    try do
      system_prompt = build_system_prompt(world, instructions)
      tools = build_worker_tools(local_state, sim_id)

      start_opts =
        [
          initial_state: %{
            system_prompt: system_prompt,
            model: model,
            tools: tools
          },
          stream_options: stream_options
        ]
        |> maybe_put(:stream_fn, stream_fn)

      case SubagentSupervisor.start_subagent(start_opts) do
        {:ok, agent} ->
          try do
            with {:ok, collector} <- start_collector(agent) do
              unsubscribe = AgentCore.subscribe(agent, collector)

              try do
                with :ok <-
                       AgentCore.prompt(
                         agent,
                         "Begin the visit. Use tools as needed and call finish_visit when all assigned work is complete."
                       ),
                     :ok <- AgentCore.wait_for_idle(agent, timeout: timeout_ms) do
                  safe_unsubscribe(unsubscribe)

                  with {:ok, worker_state} <- flush_collector(collector) do
                    tool_results = worker_state.tool_results
                    raw_events = extract_events(tool_results)
                    summary = build_summary(tool_results)

                    if worker_state.errors != [] and
                         not Enum.any?(
                           raw_events,
                           &(event_kind(&1) == "physical_worker_finished")
                         ) do
                      {:error, {:worker_failed, worker_state.errors}}
                    else
                      events =
                        raw_events
                        |> ensure_started(instructions)
                        |> ensure_finished(summary)
                        |> normalize_event_order()

                      {:ok,
                       %{
                         events: events,
                         summary: summary,
                         tool_calls: format_tool_calls(tool_results),
                         turn_count: worker_state.turn_count
                       }}
                    end
                  else
                    {:error, reason} ->
                      {:error, {:worker_failed, reason}}
                  end
                else
                  {:error, :timeout} ->
                    {:error, {:worker_failed, :timeout}}

                  {:error, reason} ->
                    {:error, {:worker_failed, reason}}
                end
              after
                safe_unsubscribe(unsubscribe)
                stop_collector(collector)
              end
            end
          after
            stop_subagent(agent)
          end

        {:error, reason} ->
          {:error, {:worker_failed, reason}}
      end
    after
      Agent.stop(local_state, :normal)
    end
  end

  defp build_system_prompt(world, instructions) do
    machine = get(world, :machine, %{})
    slots = get(machine, :slots, %{})
    storage = get(world, :storage, %{})
    storage_inv = get(storage, :inventory, %{})
    catalog = get(world, :catalog, %{})

    slot_text =
      slots
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {slot_id, slot} ->
        item_id = get(slot, :item_id)
        inv = get(slot, :inventory, 0)
        price = get(slot, :price)

        if item_id do
          item_info = Map.get(catalog, item_id, %{})
          name = Map.get(item_info, :display_name, item_id)
          "  #{slot_id}: #{name} (#{inv} units, $#{format_price(price)})"
        else
          "  #{slot_id}: [empty]"
        end
      end)
      |> Enum.join("\n")

    storage_text =
      if map_size(storage_inv) == 0 do
        "  (empty)"
      else
        storage_inv
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map(fn {item_id, qty} ->
          item_info = Map.get(catalog, item_id, %{})
          name = Map.get(item_info, :display_name, item_id)
          "  #{name} (#{item_id}): #{qty} units"
        end)
        |> Enum.join("\n")
      end

    cash_in_machine = get(world, :cash_in_machine, 0.0)

    """
    You are the physical worker for a vending machine business.

    You operate on-site only. You do not order inventory or manage the bank beyond
    collecting cash already in the machine. You may inspect inventory, stock slots,
    collect cash, set prices, and keep private worker notes.

    ## Current Machine State
    #{slot_text}

    Cash in machine: $#{format_price(cash_in_machine)}

    ## Storage
    #{storage_text}

    ## Operator Instructions
    #{instructions}

    ## Rules
    - You may use get_inventory and memory tools freely.
    - You may perform multiple operational actions in one visit: stock_products, collect_cash, set_price.
    - Maintain a consistent local view across your actions during this visit.
    - Only stock items that are currently in storage.
    - Do not mix different products in a single slot.
    - When your work is complete, call finish_visit exactly once with a concise summary.
    - After finish_visit, stop making tool calls.
    """
  end

  defp build_worker_tools(local_state, sim_id) do
    [
      get_inventory_tool(local_state)
      | MemoryTools.build(sim_id: "#{sim_id}/physical_worker")
    ] ++
      [
        stock_products_tool(local_state),
        collect_cash_tool(local_state),
        set_price_tool(local_state),
        finish_visit_tool()
      ]
  end

  defp get_inventory_tool(local_state) do
    %AgentTool{
      name: "get_inventory",
      description: "Get the current inventory of machine slots, storage, and machine cash.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Get Inventory",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        snapshot = snapshot(local_state)
        slots = snapshot.machine_slots
        storage_inv = snapshot.storage_inventory
        catalog = snapshot.catalog

        slot_lines =
          slots
          |> Enum.sort_by(fn {id, _} -> id end)
          |> Enum.map(fn {slot_id, slot} ->
            item_id = get(slot, :item_id)
            inv = get(slot, :inventory, 0)
            price = get(slot, :price)

            if item_id do
              item_info = Map.get(catalog, item_id, %{})
              name = Map.get(item_info, :display_name, item_id)
              "#{slot_id}: #{name} — #{inv} units @ $#{format_price(price)}"
            else
              "#{slot_id}: [empty]"
            end
          end)
          |> Enum.join("\n")

        storage_lines =
          if map_size(storage_inv) == 0 do
            "(empty)"
          else
            storage_inv
            |> Enum.sort_by(fn {id, _} -> id end)
            |> Enum.map(fn {item_id, qty} -> "#{item_id}: #{qty} units" end)
            |> Enum.join("\n")
          end

        text = """
        Machine Slots:
        #{slot_lines}

        Storage:
        #{storage_lines}

        Cash in machine: $#{format_price(snapshot.cash_in_machine)}
        """

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(text)],
           details: %{
             "event" =>
               Events.machine_inventory_checked(%{
                 "slots" => slots,
                 "storage" => storage_inv,
                 "cash_in_machine" => snapshot.cash_in_machine
               })
           },
           trust: :trusted
         }}
      end
    }
  end

  defp stock_products_tool(local_state) do
    %AgentTool{
      name: "stock_products",
      description: "Stock a machine slot with products from storage.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "slot_id" => %{"type" => "string", "description" => "Machine slot id, for example A1"},
          "item_id" => %{"type" => "string", "description" => "Item id to stock"},
          "quantity" => %{"type" => "integer", "description" => "Units to move from storage"}
        },
        "required" => ["slot_id", "item_id", "quantity"],
        "additionalProperties" => false
      },
      label: "Stock Products",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        slot_id = Map.get(params, "slot_id", "")
        item_id = Map.get(params, "item_id", "")
        quantity = Map.get(params, "quantity", 0)
        snapshot = snapshot(local_state)
        slots = snapshot.machine_slots
        storage_inv = snapshot.storage_inventory
        slot = Map.get(slots, slot_id)
        storage_qty = Map.get(storage_inv, item_id, 0)

        cond do
          is_nil(slot) ->
            rejected_result("physical_worker", "Invalid slot #{slot_id}")

          quantity <= 0 ->
            rejected_result("physical_worker", "Quantity must be positive")

          storage_qty < quantity ->
            rejected_result(
              "physical_worker",
              "Only #{storage_qty} units of #{item_id} are available in storage"
            )

          get(slot, :item_id) != nil and get(slot, :item_id) != item_id ->
            rejected_result(
              "physical_worker",
              "Slot #{slot_id} already contains #{get(slot, :item_id)}"
            )

          true ->
            update_snapshot(local_state, fn current ->
              slot = Map.get(current.machine_slots, slot_id, %{})
              current_inv = get(slot, :inventory, 0)
              catalog = current.catalog

              new_price =
                get(slot, :price) ||
                  catalog
                  |> Map.get(item_id, %{})
                  |> Map.get(:reference_price, 2.0)

              new_slot =
                slot
                |> Map.put(:item_id, item_id)
                |> Map.put(:inventory, current_inv + quantity)
                |> Map.put(:price, new_price)

              %{
                current
                | machine_slots: Map.put(current.machine_slots, slot_id, new_slot),
                  storage_inventory:
                    Map.put(current.storage_inventory, item_id, storage_qty - quantity)
              }
            end)

            {:ok,
             %AgentToolResult{
               content: [
                 AgentCore.text_content("Stocked #{quantity} units of #{item_id} into #{slot_id}")
               ],
               details: %{
                 "event" => Events.machine_stocked(slot_id, item_id, quantity, quantity)
               },
               trust: :trusted
             }}
        end
      end
    }
  end

  defp collect_cash_tool(local_state) do
    %AgentTool{
      name: "collect_cash",
      description: "Collect all cash currently trapped in the machine.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Collect Cash",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        snapshot = snapshot(local_state)
        cash = snapshot.cash_in_machine

        if cash <= 0 do
          rejected_result("physical_worker", "No cash is available to collect")
        else
          update_snapshot(local_state, fn current -> %{current | cash_in_machine: 0.0} end)

          {:ok,
           %AgentToolResult{
             content: [
               AgentCore.text_content("Collected $#{format_price(cash)} from the machine")
             ],
             details: %{"event" => Events.cash_collected(cash)},
             trust: :trusted
           }}
        end
      end
    }
  end

  defp set_price_tool(local_state) do
    %AgentTool{
      name: "set_price",
      description: "Set the selling price for a stocked machine slot.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "slot_id" => %{"type" => "string", "description" => "Slot to reprice"},
          "new_price" => %{"type" => "number", "description" => "New dollar price"}
        },
        "required" => ["slot_id", "new_price"],
        "additionalProperties" => false
      },
      label: "Set Price",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        slot_id = Map.get(params, "slot_id", "")
        new_price = Map.get(params, "new_price", 0.0)
        snapshot = snapshot(local_state)
        slot = Map.get(snapshot.machine_slots, slot_id)

        cond do
          is_nil(slot) ->
            rejected_result("physical_worker", "Invalid slot #{slot_id}")

          get(slot, :item_id) == nil ->
            rejected_result("physical_worker", "Cannot price empty slot #{slot_id}")

          new_price <= 0 ->
            rejected_result("physical_worker", "Price must be positive")

          true ->
            old_price = get(slot, :price, 0.0) || 0.0

            update_snapshot(local_state, fn current ->
              updated_slot = Map.put(slot, :price, new_price)
              %{current | machine_slots: Map.put(current.machine_slots, slot_id, updated_slot)}
            end)

            {:ok,
             %AgentToolResult{
               content: [
                 AgentCore.text_content("Set price for #{slot_id} to $#{format_price(new_price)}")
               ],
               details: %{"event" => Events.price_set(slot_id, new_price, old_price)},
               trust: :trusted
             }}
        end
      end
    }
  end

  defp finish_visit_tool do
    %AgentTool{
      name: "finish_visit",
      description: "Finish the visit with a concise operator-facing summary.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "summary" => %{"type" => "string", "description" => "Short visit summary"}
        },
        "required" => ["summary"],
        "additionalProperties" => false
      },
      label: "Finish Visit",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        summary = Map.get(params, "summary", "Visit complete.")

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Visit complete: #{summary}")],
           details: %{"event" => Events.physical_worker_finished(summary, [])},
           trust: :trusted
         }}
      end
    }
  end

  defp rejected_result(actor_id, reason) do
    {:ok,
     %AgentToolResult{
       content: [AgentCore.text_content("Error: #{reason}")],
       details: %{"event" => Events.action_rejected(actor_id, reason)},
       trust: :trusted
     }}
  end

  defp build_local_snapshot(world) do
    %{
      machine_slots: get(get(world, :machine, %{}), :slots, %{}),
      storage_inventory: get(get(world, :storage, %{}), :inventory, %{}),
      cash_in_machine: get(world, :cash_in_machine, 0.0),
      catalog: get(world, :catalog, %{})
    }
  end

  defp snapshot(local_state), do: Agent.get(local_state, & &1)
  defp update_snapshot(local_state, fun), do: Agent.update(local_state, fun)

  defp start_collector(agent) do
    pid =
      spawn(fn ->
        collector_loop(agent, %{tool_results: [], turn_count: 0, errors: []})
      end)

    {:ok, pid}
  end

  defp collector_loop(agent, state) do
    receive do
      {:agent_event, {:tool_execution_end, _id, name, result, is_error}} ->
        next_state = %{
          state
          | tool_results:
              state.tool_results ++ [%{tool_name: name, result: result, is_error: is_error}]
        }

        collector_loop(agent, next_state)

      {:agent_event, {:turn_end, _message, _tool_results}} ->
        turn_count = state.turn_count + 1

        if turn_count >= @worker_max_turns do
          AgentCore.abort(agent)
        end

        collector_loop(agent, %{state | turn_count: turn_count})

      {:agent_event, {:error, reason, _partial_state}} ->
        collector_loop(agent, %{state | errors: state.errors ++ [reason]})

      {:agent_event, {:canceled, reason}} ->
        collector_loop(agent, %{state | errors: state.errors ++ [reason]})

      {:flush_worker_events, from, ref} ->
        send(from, {:worker_events, ref, drain_collector_mailbox(state)})

      _other ->
        collector_loop(agent, state)
    end
  end

  defp flush_collector(collector) do
    ref = make_ref()
    send(collector, {:flush_worker_events, self(), ref})

    receive do
      {:worker_events, ^ref, state} ->
        {:ok, state}
    after
      1_000 ->
        {:error, :collector_timeout}
    end
  end

  defp drain_collector_mailbox(state) do
    receive do
      {:agent_event, {:tool_execution_end, _id, name, result, is_error}} ->
        next_state = %{
          state
          | tool_results:
              state.tool_results ++ [%{tool_name: name, result: result, is_error: is_error}]
        }

        drain_collector_mailbox(next_state)

      {:agent_event, {:turn_end, _message, _tool_results}} ->
        drain_collector_mailbox(%{state | turn_count: state.turn_count + 1})

      {:agent_event, {:error, reason, _partial_state}} ->
        drain_collector_mailbox(%{state | errors: state.errors ++ [reason]})

      {:agent_event, {:canceled, reason}} ->
        drain_collector_mailbox(%{state | errors: state.errors ++ [reason]})
    after
      0 ->
        state
    end
  end

  defp stop_collector(collector) do
    if is_pid(collector) and Process.alive?(collector) do
      Process.exit(collector, :normal)
    end

    :ok
  end

  defp safe_unsubscribe(unsubscribe) when is_function(unsubscribe, 0) do
    unsubscribe.()
    :ok
  rescue
    _ -> :ok
  end

  defp safe_unsubscribe(_unsubscribe), do: :ok

  defp stop_subagent(agent) do
    case SubagentSupervisor.stop_subagent(agent) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp extract_events(tool_results) do
    Enum.flat_map(tool_results, fn %{result: result} ->
      details = Map.get(result, :details, %{}) || %{}

      cond do
        is_list(Map.get(details, "events")) -> Map.get(details, "events", [])
        is_list(Map.get(details, :events)) -> Map.get(details, :events, [])
        not is_nil(Map.get(details, "event")) -> [Map.get(details, "event")]
        not is_nil(Map.get(details, :event)) -> [Map.get(details, :event)]
        true -> []
      end
    end)
  end

  defp ensure_started(events, instructions) do
    if Enum.any?(events, &(event_kind(&1) == "physical_worker_started")) do
      events
    else
      [Events.physical_worker_started(instructions) | events]
    end
  end

  defp ensure_finished(events, summary) do
    if Enum.any?(events, &(event_kind(&1) == "physical_worker_finished")) do
      events
    else
      events ++ [Events.physical_worker_finished(summary, [])]
    end
  end

  defp normalize_event_order(events) do
    events
    |> Enum.with_index()
    |> Enum.sort_by(fn {event, idx} -> {event_priority(event), idx} end)
    |> Enum.map(fn {event, _idx} -> event end)
  end

  defp event_priority(event) do
    case event_kind(event) do
      "physical_worker_started" -> 0
      "physical_worker_finished" -> 2
      _ -> 1
    end
  end

  defp event_kind(%{kind: kind}), do: kind
  defp event_kind(%{"kind" => kind}), do: kind
  defp event_kind(_), do: nil

  defp build_summary(tool_results) do
    explicit_summary =
      Enum.find_value(tool_results, fn %{result: result} ->
        details = Map.get(result, :details, %{}) || %{}

        case Map.get(details, "event") || Map.get(details, :event) do
          %{kind: "physical_worker_finished", payload: payload} ->
            get(payload, :summary, nil)

          %{"kind" => "physical_worker_finished", "payload" => payload} ->
            get(payload, :summary, nil)

          _ ->
            nil
        end
      end)

    if is_binary(explicit_summary) and String.trim(explicit_summary) != "" do
      explicit_summary
    else
      actions =
        tool_results
        |> Enum.map(fn %{tool_name: name, result: result} ->
          text = AgentCore.get_text(result) |> String.trim()

          if text == "" do
            nil
          else
            "#{name}: #{text}"
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&String.starts_with?(&1, "get_inventory:"))

      if actions == [] do
        "Worker visit completed with no operational changes."
      else
        Enum.join(actions, "; ")
      end
    end
  end

  defp format_tool_calls(tool_results) do
    Enum.map(tool_results, fn %{tool_name: name, result: result, is_error: is_error} ->
      %{
        tool_name: name,
        result_text: AgentCore.get_text(result),
        result_details: Map.get(result, :details),
        is_error: is_error
      }
    end)
  end

  defp normalize_stream_options(%StreamOptions{} = opts), do: opts

  defp normalize_stream_options(opts) when is_map(opts) do
    allowed_keys =
      Map.keys(%StreamOptions{})
      |> Enum.reject(&(&1 == :__struct__))

    opts
    |> Map.take(allowed_keys)
    |> then(&struct(StreamOptions, &1))
  end

  defp normalize_stream_options(_opts), do: %StreamOptions{}

  defp format_price(nil), do: "0.00"
  defp format_price(price) when is_float(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
