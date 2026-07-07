defmodule LemonSim.Examples.VendingBench.SupplierOrders do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.Commands.PlaceSupplierOrder
  alias LemonSim.Examples.VendingBench.Facts.SupplierOrderPlaced
  alias LemonSim.Examples.VendingBench.{Events, Suppliers}
  alias LemonSim.Kernel.State
  alias LemonSim.Examples.VendingBench.DayRollover

  import LemonSim.Examples.VendingBench.Support

  def apply_supplier_message_sent(state, event) do
    to = get(event.payload, :to, "")
    subject = get(event.payload, :subject, "")
    body = get(event.payload, :body, "")

    state =
      state
      |> State.update_world(fn world ->
        outbox = get(world, :outbox, [])

        message = %{
          to: to,
          subject: subject,
          body: body,
          day: get(world, :day_number, 1),
          time: get(world, :time_minutes, 540)
        }

        world
        |> Map.put(:outbox, outbox ++ [message])
        |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 10)
      end)
      |> State.append_event(event)

    DayRollover.maybe_rollover(state)
  end

  def apply_supplier_reply_received(state, event) do
    supplier_id = get(event.payload, :supplier_id, "")
    message = get(event.payload, :message, "")
    metadata = get(event.payload, :metadata, %{})

    state =
      state
      |> State.update_world(fn world ->
        inbox = get(world, :inbox, [])
        replies = get(world, :supplier_reply_history, [])
        kind = get(metadata, :kind, "reply")

        inbox_item = %{
          from: supplier_id,
          subject: supplier_reply_subject(kind),
          body: message,
          day: get(world, :day_number, 1),
          metadata: metadata
        }

        reply_entry =
          inbox_item
          |> Map.put(:time, get(world, :time_minutes, 540))

        quote_history =
          if kind == "quote" do
            get(world, :supplier_quote_history, []) ++ [reply_entry]
          else
            get(world, :supplier_quote_history, [])
          end

        world
        |> Map.put(:inbox, inbox ++ [inbox_item])
        |> Map.put(:supplier_reply_history, replies ++ [reply_entry])
        |> Map.put(:supplier_quote_history, quote_history)
      end)
      |> State.append_event(event)

    {:ok, state, :skip}
  end

  def apply_place_supplier_order(state, event) do
    command = PlaceSupplierOrder.new(event.payload)
    base_state = State.append_event(state, event)

    case quote_supplier_order(state, command) do
      {:ok, fact_event} ->
        apply_supplier_order_placed(base_state, fact_event)

      {:error, reason} ->
        apply_action_rejected(base_state, Events.action_rejected(command.actor, reason))
    end
  end

  def apply_supplier_email(state, event) do
    payload =
      event.payload
      |> Map.put_new("actor", "operator")
      |> Map.put(
        "item_id",
        get(event.payload, :ordered_item_id, get(event.payload, :item_id, ""))
      )

    command = PlaceSupplierOrder.new(payload)

    case quote_supplier_order(state, command) do
      {:ok, fact_event} ->
        apply_supplier_order_placed(state, fact_event)

      {:error, reason} ->
        apply_action_rejected(state, Events.action_rejected(command.actor, reason))
    end
  end

  defp quote_supplier_order(state, %PlaceSupplierOrder{} = command) do
    world = state.world
    current_day = get(world, :day_number, 1)
    balance = get(world, :bank_balance, 0.0)

    case Suppliers.process_order(
           command.supplier_id,
           command.item_id,
           command.quantity,
           current_day,
           negotiated?: command.negotiated?
         ) do
      {:ok, %{cost: cost} = quote} ->
        if cost > balance do
          {:error,
           "Insufficient funds. Order costs $#{format_price(cost)} but balance is $#{format_price(balance)}."}
        else
          {:ok,
           command
           |> SupplierOrderPlaced.from_quote(quote)
           |> Events.supplier_order_placed()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_supplier_order_placed(state, event) do
    supplier_id = get(event.payload, :supplier_id, "")
    item_id = get(event.payload, :item_id, "")
    quantity = get(event.payload, :quantity, 0)
    cost = get(event.payload, :cost, 0.0)
    delivery_day = get(event.payload, :delivery_day, 1)
    delivered_item_id = get(event.payload, :delivered_item_id, item_id)
    ordered_item_id = get(event.payload, :ordered_item_id, item_id)
    substituted_item_id = get(event.payload, :substituted_item_id)
    delivery_delay_days = get(event.payload, :delivery_delay_days, 0)
    supplier_issue? = get(event.payload, :supplier_issue, false)

    state =
      state
      |> State.update_world(fn world ->
        balance = get(world, :bank_balance, 0.0)
        pending = get(world, :pending_deliveries, [])
        supplier_order_history = get(world, :supplier_order_history, [])
        supplier_incident_history = get(world, :supplier_incident_history, [])

        new_delivery = %{
          supplier_id: supplier_id,
          item_id: delivered_item_id,
          ordered_item_id: ordered_item_id,
          quantity: quantity,
          cost: cost,
          delivery_day: delivery_day,
          ordered_day: get(world, :day_number, 1),
          delivery_delay_days: delivery_delay_days,
          substituted_item_id: substituted_item_id
        }

        incident =
          if supplier_issue? do
            [
              %{
                supplier_id: supplier_id,
                ordered_item_id: ordered_item_id,
                delivered_item_id: delivered_item_id,
                delivery_delay_days: delivery_delay_days,
                substituted_item_id: substituted_item_id,
                day: get(world, :day_number, 1)
              }
            ]
          else
            []
          end

        world
        |> Map.put(:bank_balance, Float.round(balance - cost, 2))
        |> Map.put(:pending_deliveries, pending ++ [new_delivery])
        |> Map.put(:supplier_order_history, supplier_order_history ++ [new_delivery])
        |> Map.put(:supplier_incident_history, supplier_incident_history ++ incident)
        |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 25)
      end)
      |> State.append_event(event)

    case DayRollover.maybe_rollover(state) do
      {:ok, next_state, :skip} ->
        {:ok, next_state,
         {:decide,
          "Order placed. $#{format_price(cost)} deducted. Delivery on day #{delivery_day}."}}

      other ->
        other
    end
  end

  defp supplier_reply_subject("bounce"), do: "Message bounced"
  defp supplier_reply_subject("quote"), do: "Supplier quote"
  defp supplier_reply_subject("order_confirmed"), do: "Order confirmed"
  defp supplier_reply_subject("order_rejected"), do: "Order rejected"
  defp supplier_reply_subject("supplier_shutdown"), do: "Supplier shutdown"
  defp supplier_reply_subject(_kind), do: "Supplier reply"
end
