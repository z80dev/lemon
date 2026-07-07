defmodule LemonSim.Examples.TcgShop.Updaters.Suppliers do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Catalog
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_order_product_line(%State{} = state, event) do
    line_id = get(event.payload, "line_id")
    quantity = as_int(get(event.payload, "quantity", 0))
    line = Catalog.line(line_id)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(quantity),
         {:ok, line} <- ensure_line(line),
         allocated_quantity <- allocated_quantity(line, quantity, state.world),
         :ok <- ensure_positive_allocation(allocated_quantity),
         cost <- Float.round(line.unit_cost * allocated_quantity, 2),
         :ok <- ensure_supplier_credit(state.world, cost) do
      day = get(state.world, :day_number, 1)
      delivery_day = day + line.supplier_delay_days
      terms_days = get(state.world, :supplier_terms_days, 7)
      invoice_id = supplier_invoice_id(state.world, day, line_id)
      supplier = supplier_for(line.franchise)

      order = %{
        day: day,
        line_id: line_id,
        requested_quantity: quantity,
        quantity: allocated_quantity,
        unit_cost: line.unit_cost,
        cost: cost,
        delivery_day: delivery_day,
        invoice_id: invoice_id,
        invoice_due_day: delivery_day + terms_days,
        payment_terms_days: terms_days,
        payment_status: "invoiced",
        supplier: supplier,
        supplier_standing: supplier_account_standing(state.world, supplier),
        allocation_rate: Float.round(allocated_quantity / quantity, 2),
        allocation_note: allocation_note(quantity, allocated_quantity, line.franchise)
      }

      invoice = supplier_invoice_for_order(order)

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update(:pending_deliveries, [order], &(&1 ++ [order]))
          |> Map.update(:supplier_order_history, [order], &(&1 ++ [order]))
          |> Map.update(:pending_supplier_invoices, [invoice], &(&1 ++ [invoice]))
          |> Map.update(:supplier_invoice_history, [invoice], &(&1 ++ [invoice]))
          |> Staffing.consume_staff_hours(
            Float.round(0.4 + allocated_quantity * 0.03, 2),
            "supplier_order"
          )
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "ordered #{allocated_quantity}/#{quantity} allocated units of #{line_id} for day #{delivery_day}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_file_supplier_claim(%State{} = state, event) do
    invoice_id = get(event.payload, "invoice_id")
    damaged_units = as_int(get(event.payload, "damaged_units", 0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(damaged_units),
         {:ok, receipt} <- claimable_delivery_receipt(state.world, invoice_id, damaged_units) do
      day = get(state.world, :day_number, 1)
      claim_amount = supplier_claim_amount(receipt, damaged_units)

      pending_invoice? =
        Enum.any?(get(state.world, :pending_supplier_invoices, []), &(get(&1, :id) == invoice_id))

      claim = %{
        day: day,
        invoice_id: invoice_id,
        supplier: get(receipt, :supplier),
        line_id: get(receipt, :line_id),
        damaged_units: damaged_units,
        claim_amount: claim_amount,
        settlement: if(pending_invoice?, do: "invoice_credit", else: "cash_reimbursement"),
        type: "supplier_damage_claim"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> settle_supplier_claim(claim)
          |> mark_delivery_receipt_claimed(invoice_id, damaged_units, claim_amount)
          |> Map.update(:supplier_claim_history, [claim], &(&1 ++ [claim]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "filed supplier claim for #{damaged_units} damaged units"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_due_deliveries(world, day) do
    {due, pending} =
      world
      |> get(:pending_deliveries, [])
      |> Enum.split_with(&(get(&1, :delivery_day, 0) <= day))

    delivered_world =
      Enum.reduce(due, world, fn delivery, acc ->
        line_id = get(delivery, :line_id)
        qty = get(delivery, :quantity, 0)
        damaged_units = delivery_damaged_units(delivery)
        received_qty = max(0, qty - damaged_units)
        receipt = delivery_receipt(delivery, day, damaged_units, received_qty)

        acc
        |> update_in([:inventory, line_id], &receive_inventory(&1, received_qty))
        |> Map.update(:delivery_receipt_history, [receipt], &(&1 ++ [receipt]))
      end)

    Map.put(delivered_world, :pending_deliveries, pending)
  end

  def receive_inventory(nil, qty), do: %{on_hand: qty, age_days: 0}

  def receive_inventory(item, qty) do
    existing_qty = get(item, :on_hand, 0)
    existing_age = get(item, :age_days, 0)
    next_qty = existing_qty + qty

    next_age =
      if next_qty > 0 do
        Float.round(existing_qty * existing_age / next_qty, 2)
      else
        0
      end

    item
    |> Map.put(:on_hand, next_qty)
    |> Map.put(:age_days, next_age)
  end

  defp delivery_damaged_units(delivery) do
    line = Catalog.line(get(delivery, :line_id))
    qty = get(delivery, :quantity, 0)

    if get(line || %{}, :category) == "sealed" and qty >= 4 do
      1
    else
      0
    end
  end

  defp delivery_receipt(delivery, day, damaged_units, received_qty) do
    unit_cost = get(delivery, :unit_cost, 0.0)

    %{
      day: day,
      invoice_id: get(delivery, :invoice_id),
      supplier: get(delivery, :supplier),
      line_id: get(delivery, :line_id),
      ordered_quantity: get(delivery, :quantity, 0),
      received_quantity: received_qty,
      damaged_units: damaged_units,
      claimed_units: 0,
      claim_status: if(damaged_units > 0, do: "unclaimed", else: "none"),
      unit_cost: unit_cost,
      damage_value: Float.round(damaged_units * unit_cost, 2)
    }
  end

  defp ensure_positive_allocation(value),
    do: if(value > 0, do: :ok, else: {:error, :allocation_unavailable})

  defp ensure_supplier_credit(world, cost) do
    credit_limit = effective_supplier_credit_limit(world)

    if accounts_payable(world) + cost <= credit_limit do
      :ok
    else
      {:error, :supplier_credit_limit_exceeded}
    end
  end

  defp supplier_for("Pokemon"), do: "gts_distribution"
  defp supplier_for("Accessories"), do: "gts_distribution"
  defp supplier_for("One Piece"), do: "premium_secondary"
  defp supplier_for(_), do: "alliance_distribution"

  defp supplier_invoice_id(world, day, line_id) do
    next_number = length(get(world, :supplier_order_history, [])) + 1
    "inv_#{day}_#{line_id}_#{next_number}"
  end

  defp supplier_invoice_for_order(order) do
    %{
      id: get(order, :invoice_id),
      day: get(order, :day),
      supplier: get(order, :supplier),
      line_id: get(order, :line_id),
      amount_original: get(order, :cost, 0.0),
      amount_due: get(order, :cost, 0.0),
      due_day: get(order, :invoice_due_day),
      payment_terms_days: get(order, :payment_terms_days, 0),
      status: "open",
      type: "created",
      late_fee_total: 0.0
    }
  end

  defp claimable_delivery_receipt(world, invoice_id, damaged_units) do
    receipt =
      world
      |> get(:delivery_receipt_history, [])
      |> Enum.find(&(get(&1, :invoice_id) == invoice_id))

    cond do
      is_nil(receipt) ->
        {:error, :unknown_delivery_receipt}

      get(receipt, :damaged_units, 0) <= get(receipt, :claimed_units, 0) ->
        {:error, :no_unclaimed_delivery_damage}

      damaged_units > get(receipt, :damaged_units, 0) - get(receipt, :claimed_units, 0) ->
        {:error, :claim_exceeds_unclaimed_damage}

      true ->
        {:ok, receipt}
    end
  end

  defp supplier_claim_amount(receipt, damaged_units) do
    Float.round(damaged_units * get(receipt, :unit_cost, 0.0), 2)
  end

  defp settle_supplier_claim(world, claim) do
    invoice_id = get(claim, :invoice_id)
    claim_amount = get(claim, :claim_amount, 0.0)

    case Enum.split_with(
           get(world, :pending_supplier_invoices, []),
           &(get(&1, :id) == invoice_id)
         ) do
      {[invoice], rest} ->
        credited_invoice =
          invoice
          |> Map.update(:claim_credit_total, claim_amount, &Float.round(&1 + claim_amount, 2))
          |> Map.update(:amount_due, 0.0, &Float.round(max(0.0, &1 - claim_amount), 2))

        credit_entry = %{
          day: get(claim, :day),
          id: invoice_id,
          supplier: get(claim, :supplier),
          line_id: get(claim, :line_id),
          amount: claim_amount,
          type: "credit_memo"
        }

        world
        |> Map.put(:pending_supplier_invoices, [credited_invoice | rest])
        |> Map.update(:supplier_invoice_history, [credit_entry], &(&1 ++ [credit_entry]))

      _ ->
        world
        |> Map.update!(:bank_balance, &Float.round(&1 + claim_amount, 2))
    end
  end

  defp mark_delivery_receipt_claimed(world, invoice_id, damaged_units, claim_amount) do
    receipts =
      world
      |> get(:delivery_receipt_history, [])
      |> Enum.map(fn receipt ->
        if get(receipt, :invoice_id) == invoice_id do
          claimed_units = get(receipt, :claimed_units, 0) + damaged_units
          remaining_units = get(receipt, :damaged_units, 0) - claimed_units

          receipt
          |> Map.put(:claimed_units, claimed_units)
          |> Map.update(:claim_amount, claim_amount, &Float.round(&1 + claim_amount, 2))
          |> Map.put(
            :claim_status,
            if(remaining_units > 0, do: "partially_claimed", else: "claimed")
          )
        else
          receipt
        end
      end)

    Map.put(world, :delivery_receipt_history, receipts)
  end

  def apply_due_supplier_invoices(world, day) do
    {world, pending} =
      world
      |> get(:pending_supplier_invoices, [])
      |> Enum.reduce({world, []}, fn invoice, {acc, pending_acc} ->
        cond do
          get(invoice, :due_day, 0) > day ->
            {acc, pending_acc ++ [invoice]}

          get(acc, :bank_balance, 0.0) >= get(invoice, :amount_due, 0.0) ->
            amount = Float.round(get(invoice, :amount_due, 0.0), 2)

            paid = %{
              id: get(invoice, :id),
              day: day,
              supplier: get(invoice, :supplier),
              line_id: get(invoice, :line_id),
              amount_paid: amount,
              status: "paid",
              type: "paid"
            }

            next =
              acc
              |> Map.update!(:bank_balance, &Float.round(&1 - amount, 2))
              |> Map.update(:supplier_invoice_history, [paid], &(&1 ++ [paid]))
              |> update_supplier_account(get(invoice, :supplier), day, :paid, invoice)

            {next, pending_acc}

          true ->
            {next, overdue} = mark_supplier_invoice_overdue(acc, invoice, day)
            {next, pending_acc ++ [overdue]}
        end
      end)

    Map.put(world, :pending_supplier_invoices, pending)
  end

  defp mark_supplier_invoice_overdue(world, invoice, day) do
    late_fee =
      if day > get(invoice, :due_day, 0) and get(invoice, :last_late_fee_day, nil) != day do
        Float.round(
          get(invoice, :amount_due, 0.0) * get(world, :supplier_late_fee_rate, 0.035),
          2
        )
      else
        0.0
      end

    overdue =
      invoice
      |> Map.put(:status, "overdue")
      |> Map.update(:amount_due, late_fee, &Float.round(&1 + late_fee, 2))
      |> Map.update(:late_fee_total, late_fee, &Float.round(&1 + late_fee, 2))
      |> maybe_put_late_fee_day(day, late_fee)

    if late_fee > 0.0 do
      fee_entry = %{
        id: get(invoice, :id),
        day: day,
        supplier: get(invoice, :supplier),
        line_id: get(invoice, :line_id),
        late_fee: late_fee,
        status: "overdue",
        type: "late_fee"
      }

      next =
        world
        |> Map.update(:supplier_invoice_history, [fee_entry], &(&1 ++ [fee_entry]))
        |> update_supplier_account(get(invoice, :supplier), day, :late_fee, overdue)

      {next, overdue}
    else
      {world, overdue}
    end
  end

  defp maybe_put_late_fee_day(invoice, day, late_fee) when late_fee > 0.0,
    do: Map.put(invoice, :last_late_fee_day, day)

  defp maybe_put_late_fee_day(invoice, _day, _late_fee), do: invoice

  defp accounts_payable(world) do
    world
    |> get(:pending_supplier_invoices, [])
    |> Enum.reduce(0.0, fn invoice, acc -> acc + get(invoice, :amount_due, 0.0) end)
    |> Float.round(2)
  end

  defp effective_supplier_credit_limit(world) do
    base = get(world, :supplier_credit_limit, 0.0)
    Float.round(max(0.0, base + supplier_credit_adjustment(world)), 2)
  end

  defp supplier_credit_adjustment(world) do
    average = average_supplier_standing(world)

    cond do
      average > 55 -> min(750.0, (average - 55) * 20)
      average < 55 -> max(-750.0, (average - 55) * 25)
      true -> 0.0
    end
  end

  defp average_supplier_standing(world) do
    accounts = world |> get(:supplier_accounts, %{}) |> Map.values()

    if accounts == [] do
      55.0
    else
      accounts
      |> Enum.reduce(0.0, fn account, acc -> acc + get(account, :standing, 55) end)
      |> Kernel./(length(accounts))
      |> Float.round(2)
    end
  end

  defp supplier_account_standing(world, supplier) do
    world
    |> get(:supplier_accounts, %{})
    |> Map.get(supplier, %{})
    |> get(:standing, 55)
  end

  defp update_supplier_account(world, nil, _day, _reason, _invoice), do: world

  defp update_supplier_account(world, supplier, day, reason, invoice) do
    accounts = get(world, :supplier_accounts, %{})
    account = Map.get(accounts, supplier, default_supplier_account(supplier))
    before = get(account, :standing, 55)
    due_day = get(invoice, :due_day, day)

    delta =
      case reason do
        :paid -> if(day <= due_day, do: 3, else: 1)
        :late_fee -> -8
      end

    after_standing = clamp_int(before + delta, 0, 100)

    updated =
      account
      |> Map.put(:standing, after_standing)
      |> Map.put(:status, supplier_account_status(after_standing))
      |> Map.put(:last_event_day, day)
      |> maybe_increment_supplier_counter(reason)

    history = %{
      day: day,
      supplier: supplier,
      invoice_id: get(invoice, :id),
      line_id: get(invoice, :line_id),
      standing_before: before,
      standing_after: after_standing,
      delta: delta,
      status: get(updated, :status),
      type: Atom.to_string(reason)
    }

    world
    |> Map.put(:supplier_accounts, Map.put(accounts, supplier, updated))
    |> Map.update(:supplier_account_history, [history], &(&1 ++ [history]))
  end

  defp default_supplier_account(supplier) do
    %{
      supplier: supplier,
      standing: 55,
      status: "current",
      invoices_paid: 0,
      late_invoices: 0,
      last_event_day: nil
    }
  end

  defp maybe_increment_supplier_counter(account, :paid),
    do: Map.update(account, :invoices_paid, 1, &(&1 + 1))

  defp maybe_increment_supplier_counter(account, :late_fee),
    do: Map.update(account, :late_invoices, 1, &(&1 + 1))

  defp supplier_account_status(standing) when standing >= 70, do: "preferred"
  defp supplier_account_status(standing) when standing < 45, do: "strained"
  defp supplier_account_status(_standing), do: "current"

  defp allocated_quantity(line, requested_quantity, world) do
    if line.category == "accessory" do
      requested_quantity
    else
      min(requested_quantity, allocation_limit(line, world))
    end
  end

  defp allocation_limit(line, world) do
    reputation = get(world, :reputation, 50)
    pulse = List.last(get(world, :market_pulses, [])) || %{}
    hype_penalty = if get(pulse, :featured_franchise) == line.franchise, do: 1, else: 0
    reputation_bonus = div(reputation, 30)
    standing_bonus = allocation_standing_bonus(world, supplier_for(line.franchise))

    base =
      case line.franchise do
        "One Piece" -> 3
        "Pokemon" -> 6
        "Yu-Gi-Oh!" -> 7
        "Dragon Ball Super" -> 5
        _ -> 6
      end

    max(1, base + reputation_bonus + standing_bonus - hype_penalty)
  end

  defp allocation_standing_bonus(world, supplier) do
    standing = supplier_account_standing(world, supplier)

    cond do
      standing >= 80 -> 2
      standing >= 65 -> 1
      standing < 35 -> -2
      standing < 45 -> -1
      true -> 0
    end
  end

  defp allocation_note(requested, allocated, _franchise) when allocated >= requested,
    do: "filled in full"

  defp allocation_note(_requested, _allocated, "One Piece"),
    do: "partial allocation due to scarce Bandai sealed supply"

  defp allocation_note(_requested, _allocated, "Pokemon"),
    do: "partial allocation during high Pokemon distributor demand"

  defp allocation_note(_requested, _allocated, _franchise),
    do: "partial distributor allocation"
end
