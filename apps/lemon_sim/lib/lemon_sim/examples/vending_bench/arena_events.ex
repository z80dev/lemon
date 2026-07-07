defmodule LemonSim.Examples.VendingBench.ArenaEvents do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.Events
  alias LemonSim.Kernel.State
  alias LemonSim.Examples.VendingBench.DayRollover

  import LemonSim.Examples.VendingBench.Support

  def apply_arena_message_sent(state, event) do
    from_agent_id =
      get(event.payload, :from_agent_id, get(state.world, :arena_agent_id, "operator"))

    to_agent_id = get(event.payload, :to_agent_id, "")
    subject = get(event.payload, :subject, "")
    body = get(event.payload, :body, "")
    current_agent_id = get(state.world, :arena_agent_id)

    if current_agent_id == to_agent_id and current_agent_id != from_agent_id do
      state =
        state
        |> State.update_world(fn world ->
          mailbox = get(world, :arena_mailbox, [])

          message = %{
            from_agent_id: from_agent_id,
            to_agent_id: to_agent_id,
            subject: subject,
            body: body,
            day: get(world, :day_number, 1),
            time: get(world, :time_minutes, 540)
          }

          Map.put(world, :arena_mailbox, mailbox ++ [message])
        end)
        |> State.append_event(event)

      {:ok, state, :skip}
    else
      state =
        state
        |> State.update_world(fn world ->
          outbox = get(world, :arena_outbox, [])

          message = %{
            from_agent_id: from_agent_id,
            to_agent_id: to_agent_id,
            subject: subject,
            body: body,
            day: get(world, :day_number, 1),
            time: get(world, :time_minutes, 540)
          }

          world
          |> Map.put(:arena_outbox, outbox ++ [message])
          |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 10)
        end)
        |> State.append_event(event)

      DayRollover.maybe_rollover(state)
    end
  end

  def apply_arena_money_sent(state, event) do
    amount = get(event.payload, :amount, 0.0)

    from_agent_id =
      get(event.payload, :from_agent_id, get(state.world, :arena_agent_id, "operator"))

    to_agent_id = get(event.payload, :to_agent_id, "")
    memo = get(event.payload, :memo, "")
    balance = get(state.world, :bank_balance, 0.0)
    current_agent_id = get(state.world, :arena_agent_id)

    cond do
      current_agent_id == to_agent_id and current_agent_id != from_agent_id ->
        state =
          state
          |> State.update_world(fn world ->
            payments = get(world, :arena_payments_received, [])

            payment = %{
              from_agent_id: from_agent_id,
              to_agent_id: to_agent_id,
              amount: Float.round(amount * 1.0, 2),
              memo: memo,
              day: get(world, :day_number, 1),
              time: get(world, :time_minutes, 540)
            }

            world
            |> Map.put(:bank_balance, Float.round(get(world, :bank_balance, 0.0) + amount, 2))
            |> Map.put(:arena_payments_received, payments ++ [payment])
          end)
          |> State.append_event(event)

        {:ok, state, :skip}

      amount <= 0 ->
        apply_action_rejected(
          state,
          Events.action_rejected(from_agent_id, "Arena payment amount must be positive")
        )

      amount > balance ->
        apply_action_rejected(
          state,
          Events.action_rejected(
            from_agent_id,
            "Insufficient funds. Arena payment costs $#{format_price(amount)} but balance is $#{format_price(balance)}."
          )
        )

      true ->
        state =
          state
          |> State.update_world(fn world ->
            payments = get(world, :arena_payments_sent, [])

            payment = %{
              from_agent_id: from_agent_id,
              to_agent_id: to_agent_id,
              amount: Float.round(amount * 1.0, 2),
              memo: memo,
              day: get(world, :day_number, 1),
              time: get(world, :time_minutes, 540)
            }

            world
            |> Map.put(:bank_balance, Float.round(get(world, :bank_balance, 0.0) - amount, 2))
            |> Map.put(:arena_payments_sent, payments ++ [payment])
            |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 5)
          end)
          |> State.append_event(event)

        DayRollover.maybe_rollover(state)
    end
  end

  def apply_arena_trade_completed(state, event) do
    from_agent_id =
      get(event.payload, :from_agent_id, get(state.world, :arena_agent_id, "operator"))

    to_agent_id = get(event.payload, :to_agent_id, "")
    item_id = get(event.payload, :item_id, "")
    quantity = get(event.payload, :quantity, 0)
    amount = get(event.payload, :amount, 0.0)
    storage_qty = get_in(state.world, [:storage, :inventory, item_id]) || 0
    current_agent_id = get(state.world, :arena_agent_id)

    cond do
      current_agent_id == to_agent_id and current_agent_id != from_agent_id ->
        balance = get(state.world, :bank_balance, 0.0)

        if amount > balance do
          apply_action_rejected(
            state,
            Events.action_rejected(
              to_agent_id,
              "Insufficient funds. Arena trade costs $#{format_price(amount)} but balance is $#{format_price(balance)}."
            )
          )
        else
          state =
            state
            |> State.update_world(fn world ->
              storage = DayRollover.add_to_storage(get(world, :storage, %{}), item_id, quantity)
              trades = get(world, :arena_trades, [])

              trade = %{
                from_agent_id: from_agent_id,
                to_agent_id: to_agent_id,
                item_id: item_id,
                quantity: quantity,
                amount: Float.round(amount * 1.0, 2),
                day: get(world, :day_number, 1),
                time: get(world, :time_minutes, 540)
              }

              world
              |> Map.put(:storage, storage)
              |> Map.put(:bank_balance, Float.round(get(world, :bank_balance, 0.0) - amount, 2))
              |> Map.put(:arena_trades, trades ++ [trade])
            end)
            |> State.append_event(event)

          {:ok, state, :skip}
        end

      quantity <= 0 ->
        apply_action_rejected(
          state,
          Events.action_rejected(from_agent_id, "Arena trade quantity must be positive")
        )

      amount < 0 ->
        apply_action_rejected(
          state,
          Events.action_rejected(from_agent_id, "Arena trade amount cannot be negative")
        )

      storage_qty < quantity ->
        apply_action_rejected(
          state,
          Events.action_rejected(
            from_agent_id,
            "Cannot trade #{quantity} units of #{item_id}; only #{storage_qty} available in storage"
          )
        )

      true ->
        state =
          state
          |> State.update_world(fn world ->
            storage =
              DayRollover.remove_from_storage(get(world, :storage, %{}), item_id, quantity)

            trades = get(world, :arena_trades, [])

            trade = %{
              from_agent_id: from_agent_id,
              to_agent_id: to_agent_id,
              item_id: item_id,
              quantity: quantity,
              amount: Float.round(amount * 1.0, 2),
              day: get(world, :day_number, 1),
              time: get(world, :time_minutes, 540)
            }

            world
            |> Map.put(:storage, storage)
            |> Map.put(:bank_balance, Float.round(get(world, :bank_balance, 0.0) + amount, 2))
            |> Map.put(:arena_trades, trades ++ [trade])
            |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 10)
          end)
          |> State.append_event(event)

        DayRollover.maybe_rollover(state)
    end
  end

  def apply_arena_trade_reversed(state, event) do
    from_agent_id =
      get(event.payload, :from_agent_id, get(state.world, :arena_agent_id, "operator"))

    to_agent_id = get(event.payload, :to_agent_id, "")
    item_id = get(event.payload, :item_id, "")
    quantity = get(event.payload, :quantity, 0)
    amount = get(event.payload, :amount, 0.0)
    reason = get(event.payload, :reason, "")
    current_agent_id = get(state.world, :arena_agent_id)

    if current_agent_id == from_agent_id do
      state =
        state
        |> State.update_world(fn world ->
          storage = DayRollover.add_to_storage(get(world, :storage, %{}), item_id, quantity)
          reversals = get(world, :arena_trade_reversals, [])

          reversal = %{
            from_agent_id: from_agent_id,
            to_agent_id: to_agent_id,
            item_id: item_id,
            quantity: quantity,
            amount: Float.round(amount * 1.0, 2),
            reason: reason,
            day: get(world, :day_number, 1),
            time: get(world, :time_minutes, 540)
          }

          world
          |> Map.put(:storage, storage)
          |> Map.put(:bank_balance, Float.round(get(world, :bank_balance, 0.0) - amount, 2))
          |> Map.put(:arena_trade_reversals, reversals ++ [reversal])
        end)
        |> State.append_event(event)

      {:ok, state, :skip}
    else
      apply_skip(state, event)
    end
  end

  def apply_arena_supplier_lead_shared(state, event) do
    state =
      state
      |> State.update_world(fn world ->
        leads = get(world, :arena_supplier_leads, [])

        lead =
          event.payload
          |> Map.new(fn {key, value} -> {to_known_arena_key(key), value} end)
          |> Map.put(:day, get(world, :day_number, 1))
          |> Map.put(:time, get(world, :time_minutes, 540))

        Map.put(world, :arena_supplier_leads, leads ++ [lead])
      end)
      |> State.append_event(event)

    {:ok, state, :skip}
  end

  def apply_arena_price_war_detected(state, event) do
    state =
      state
      |> State.update_world(fn world ->
        price_wars = get(world, :arena_price_wars, [])
        entry = event.payload |> Map.new(fn {key, value} -> {to_known_arena_key(key), value} end)
        Map.put(world, :arena_price_wars, price_wars ++ [entry])
      end)
      |> State.append_event(event)

    {:ok, state, :skip}
  end

  def apply_arena_collusion_signal(state, event) do
    state =
      state
      |> State.update_world(fn world ->
        signals = get(world, :arena_collusion_signals, [])
        entry = event.payload |> Map.new(fn {key, value} -> {to_known_arena_key(key), value} end)
        Map.put(world, :arena_collusion_signals, signals ++ [entry])
      end)
      |> State.append_event(event)

    {:ok, state, :skip}
  end

  defp to_known_arena_key(key) when is_atom(key), do: key
  defp to_known_arena_key("from_agent_id"), do: :from_agent_id
  defp to_known_arena_key("to_agent_id"), do: :to_agent_id
  defp to_known_arena_key("supplier_id"), do: :supplier_id
  defp to_known_arena_key("item_id"), do: :item_id
  defp to_known_arena_key("amount"), do: :amount
  defp to_known_arena_key("quantity"), do: :quantity
  defp to_known_arena_key("spread"), do: :spread
  defp to_known_arena_key("proposal"), do: :proposal
  defp to_known_arena_key("cheapest_agent_id"), do: :cheapest_agent_id
  defp to_known_arena_key("expensive_agent_id"), do: :expensive_agent_id
  defp to_known_arena_key(key), do: key
end
