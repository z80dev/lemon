defmodule LemonSim.Examples.VendingBench.Projector do
  @moduledoc false

  @spec opts() :: keyword()
  def opts do
    [
      section_builders: %{
        business_state: fn frame, _tools, _opts ->
          world = frame.world
          day = get(world, :day_number, 1)
          max_days = get(world, :max_days, 30)
          time = get(world, :time_minutes, 540)
          hours = div(time, 60)
          mins = rem(time, 60)
          balance = get(world, :bank_balance, 0.0)
          cash = get(world, :cash_in_machine, 0.0)
          weather = get(world, :weather, %{})
          season = get(world, :season, %{})

          %{
            id: :business_state,
            title: "Business Status",
            format: :text,
            content: """
            Day #{day}/#{max_days} | Time: #{hours}:#{String.pad_leading(to_string(mins), 2, "0")}
            Bank Balance: $#{format_price(balance)}
            Cash in Machine: $#{format_price(cash)}
            Net Worth: $#{format_price(balance + cash)}
            Weather: #{Map.get(weather, :kind, "mild")} (demand x#{Map.get(weather, :demand_multiplier, 1.0)})
            Season: #{Map.get(season, :name, "spring")} (demand x#{Map.get(season, :demand_multiplier, 1.0)})
            Daily Fee: $#{format_price(get(world, :daily_fee, 2.0))}
            Unpaid Fee Streak: #{get(world, :unpaid_fee_streak, 0)}/10 (bankruptcy at 10)
            """
          }
        end,
        machine_snapshot: fn frame, _tools, _opts ->
          world = frame.world
          machine = get(world, :machine, %{})
          slots = get(machine, :slots, %{})
          catalog = get(world, :catalog, %{})

          lines =
            slots
            |> Enum.sort_by(fn {id, _} -> id end)
            |> Enum.map(fn {slot_id, slot} ->
              item_id = get(slot, :item_id)
              inv = get(slot, :inventory, 0)
              price = get(slot, :price)

              if item_id do
                item_info = Map.get(catalog, item_id, %{})
                name = Map.get(item_info, :display_name, item_id)
                "  #{slot_id}: #{name} — #{inv} units @ $#{format_price(price)}"
              else
                "  #{slot_id}: [empty]"
              end
            end)
            |> Enum.join("\n")

          %{
            id: :machine_snapshot,
            title: "Machine Slots (4x3, top rows small / bottom rows large)",
            format: :text,
            content: lines
          }
        end,
        storage_snapshot: fn frame, _tools, _opts ->
          world = frame.world
          storage = get(world, :storage, %{})
          storage_inv = get(storage, :inventory, %{})
          catalog = get(world, :catalog, %{})

          content =
            if map_size(storage_inv) == 0 do
              "  (empty — order from suppliers)"
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

          %{
            id: :storage_snapshot,
            title: "Storage Warehouse",
            format: :text,
            content: content
          }
        end,
        inbox: fn frame, _tools, _opts ->
          world = frame.world
          inbox = get(world, :inbox, [])

          content =
            if inbox == [] do
              "  No messages."
            else
              inbox
              |> Enum.with_index(1)
              |> Enum.map(fn {msg, i} ->
                from = get(msg, :from, "?")
                subject = get(msg, :subject, "")
                "  #{i}. From #{from}: #{subject}"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :inbox,
            title: "Inbox (#{length(inbox)} messages)",
            format: :text,
            content: content
          }
        end,
        sales_summary: fn frame, _tools, _opts ->
          world = frame.world
          recent = get(world, :recent_sales, [])

          content =
            if recent == [] do
              "  No sales recorded yet."
            else
              total_rev =
                Enum.reduce(recent, 0.0, fn s, acc -> acc + get(s, :revenue, 0.0) end)

              total_units =
                Enum.reduce(recent, 0, fn s, acc -> acc + get(s, :quantity, 0) end)

              lines =
                recent
                |> Enum.take(-10)
                |> Enum.map(fn s ->
                  "  Slot #{get(s, :slot_id, "?")}: #{get(s, :quantity, 0)}x #{get(s, :item_id, "?")} — $#{format_price(get(s, :revenue, 0.0))}"
                end)
                |> Enum.join("\n")

              "Last day: #{total_units} units sold, $#{format_price(total_rev)} revenue\n#{lines}"
            end

          %{
            id: :sales_summary,
            title: "Recent Sales",
            format: :text,
            content: content
          }
        end,
        worker_status: fn frame, _tools, _opts ->
          world = frame.world
          count = get(world, :physical_worker_run_count, 0)
          last_report = get(world, :physical_worker_last_report)

          content =
            if last_report do
              "  Trips: #{count}\n  Last report: #{get(last_report, :summary, "N/A")} (day #{get(last_report, :day, "?")})"
            else
              "  Trips: #{count}\n  No visits yet."
            end

          %{
            id: :worker_status,
            title: "Physical Worker",
            format: :text,
            content: content
          }
        end,
        pending_deliveries: fn frame, _tools, _opts ->
          world = frame.world
          pending = get(world, :pending_deliveries, [])

          content =
            if pending == [] do
              "  No pending deliveries."
            else
              pending
              |> Enum.map(fn d ->
                "  #{get(d, :item_id, "?")} x#{get(d, :quantity, 0)} from #{get(d, :supplier_id, "?")} — arrives day #{get(d, :delivery_day, "?")}"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :pending_deliveries,
            title: "Pending Deliveries",
            format: :text,
            content: content
          }
        end,
        reminders: fn frame, _tools, _opts ->
          reminders = get(frame.world, :reminders, [])
          day = get(frame.world, :day_number, 1)

          open_reminders =
            reminders
            |> Enum.reject(&(get(&1, :status, "open") == "done"))
            |> Enum.sort_by(fn reminder -> {get(reminder, :day, 0), get(reminder, :id, "")} end)

          content =
            if open_reminders == [] do
              "  No open reminders."
            else
              open_reminders
              |> Enum.take(10)
              |> Enum.map(fn reminder ->
                due_day = get(reminder, :day, "?")
                urgency = if is_integer(due_day) and due_day <= day, do: "due", else: "later"

                "  #{get(reminder, :id, "?")} | day #{due_day} | #{urgency}: #{get(reminder, :text, "")}"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :reminders,
            title: "Open Reminders",
            format: :text,
            content: content
          }
        end,
        decision_contract: fn frame, _tools, _opts ->
          max_days = get(frame.world, :max_days, 30)

          %{
            id: :decision_contract,
            title: "Decision Contract",
            format: :markdown,
            content: """
            VENDING MACHINE OPERATOR RULES:
            - You are running a vending machine business over #{max_days} simulated days.
            - Each turn you can use SUPPORT tools (read_inbox, check_balance, supplier email, etc.) freely.
            - Do not loop on support tools. After at most 2 support tool calls, end the turn.
            - Then you must use exactly ONE TERMINAL tool to end your turn:
              * run_physical_worker — dispatch worker to stock machine, collect cash, set prices
              * wait_for_next_day — end the day and advance to tomorrow

            STRATEGY TIPS:
            - Stock the machine before waiting for the next day so sales can happen.
            - Collect cash regularly so you have funds for orders.
            - Set prices considering elasticity — higher prices reduce demand.
            - Order enough inventory but don't overspend.
            - Physical worker visits take 75 minutes and must start by 15:45 to be back by 17:00.
            - Check your inbox for delivery confirmations.
            - Use memory tools to track your strategy and supplier notes.
            - Use reminder tools for time-sensitive plans such as restocks, delayed deliveries, and follow-ups.
            - Daily fee of $2 is charged each night — maintain positive balance.
            - 10 consecutive unpaid fees = bankruptcy = game over.
            - Goal: maximize net worth and final bank money balance by day #{max_days}.
            """
          }
        end
      },
      section_order: [
        :business_state,
        :machine_snapshot,
        :storage_snapshot,
        :pending_deliveries,
        :reminders,
        :inbox,
        :sales_summary,
        :worker_status,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  defp format_price(price) when is_float(price),
    do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
