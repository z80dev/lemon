defmodule LemonSim.Examples.TcgShop.Updaters.Finance do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_manage_credit_line(%State{} = state, event) do
    action = get(event.payload, "action")
    amount = as_float(get(event.payload, "amount", 0.0))
    reason = get(event.payload, "reason", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_credit_action(action),
         :ok <- ensure_minimum(amount, 50.0),
         :ok <- ensure_credit_capacity(state.world, action, amount) do
      day = get(state.world, :day_number, 1)

      entry = %{
        day: day,
        action: action,
        amount: Float.round(amount, 2),
        reason: reason,
        balance_after: credit_line_balance_after(state.world, action, amount),
        type: action
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> apply_credit_line_action(action, amount)
          |> Map.update(:debt_history, [entry], &(&1 ++ [entry]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "#{action} credit line #{Float.round(amount, 2)}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_make_bank_deposit(%State{} = state, event) do
    amount = as_float(get(event.payload, "amount", 0.0))
    reason = get(event.payload, "reason", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(amount),
         :ok <- ensure_cash_drawer(state.world, amount) do
      day = get(state.world, :day_number, 1)

      entry = %{
        day: day,
        type: "bank_deposit",
        source: "bank_deposit",
        amount: Float.round(amount, 2),
        reason: reason
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:cash_drawer_balance, &Float.round(&1 - amount, 2))
          |> Map.update!(:bank_balance, &Float.round(&1 + amount, 2))
          |> Map.update(:cash_handling_history, [entry], &(&1 ++ [entry]))
          |> Staffing.consume_staff_hours(0.15, "bank_deposit")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "deposited $#{amount} from register cash"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_cash_drawer(world, amount) do
    if get(world, :cash_drawer_balance, 0.0) >= amount,
      do: :ok,
      else: {:error, :insufficient_register_cash}
  end

  defp ensure_credit_action(action) do
    if action in ["draw", "repay"],
      do: :ok,
      else: {:error, :invalid_credit_line_action}
  end

  defp ensure_credit_capacity(world, "draw", amount) do
    available =
      get(world, :credit_line_limit, 0.0) - get(world, :credit_line_balance, 0.0)

    if amount <= available,
      do: :ok,
      else: {:error, :credit_line_limit_exceeded}
  end

  defp ensure_credit_capacity(world, "repay", amount) do
    cond do
      amount > get(world, :credit_line_balance, 0.0) -> {:error, :repayment_exceeds_debt}
      amount > get(world, :bank_balance, 0.0) -> {:error, :insufficient_cash}
      true -> :ok
    end
  end

  def apply_store_credit_issue(world, amount, source, day) when amount > 0 do
    entry = %{
      day: day,
      source: source,
      amount: Float.round(amount, 2),
      type: "issued"
    }

    world
    |> Map.update(:store_credit_liability, amount, &Float.round(&1 + amount, 2))
    |> Map.update(:store_credit_history, [entry], &(&1 ++ [entry]))
  end

  def apply_store_credit_issue(world, _amount, _source, _day), do: world

  def apply_store_credit_redemption(world, amount, source, day) when amount > 0 do
    entry = %{
      day: day,
      source: source,
      amount: Float.round(amount, 2),
      type: "redeemed"
    }

    world
    |> Map.update(:store_credit_liability, 0.0, &Float.round(max(0.0, &1 - amount), 2))
    |> Map.update(:store_credit_history, [entry], &(&1 ++ [entry]))
  end

  def apply_store_credit_redemption(world, _amount, _source, _day), do: world

  def store_credit_redemption_for(world, revenue) when revenue > 0 do
    liability = get(world, :store_credit_liability, 0.0)
    Float.round(min(liability, revenue * 0.22), 2)
  end

  def store_credit_redemption_for(_world, _revenue), do: 0.0

  def apply_sales_tax(world, taxable_amount, source, day) when taxable_amount > 0 do
    rate = get(world, :sales_tax_rate, 0.0)
    tax = Float.round(taxable_amount * rate, 2)

    entry = %{
      day: day,
      source: source,
      taxable_sales: Float.round(taxable_amount, 2),
      tax_collected: tax,
      rate: rate,
      type: "collected"
    }

    world
    |> Map.update!(:bank_balance, &Float.round(&1 + tax, 2))
    |> Map.update(:sales_tax_liability, tax, &Float.round(&1 + tax, 2))
    |> Map.update(:tax_history, [entry], &(&1 ++ [entry]))
  end

  def apply_sales_tax(world, _taxable_amount, _source, _day), do: world

  def apply_local_sales_tax(world, taxable_amount, source, day, opts \\ [])

  def apply_local_sales_tax(world, taxable_amount, source, day, opts) when taxable_amount > 0 do
    rate = get(world, :sales_tax_rate, 0.0)
    tax = Float.round(taxable_amount * rate, 2)

    entry = %{
      day: day,
      source: source,
      taxable_sales: Float.round(taxable_amount, 2),
      tax_collected: tax,
      rate: rate,
      type: "collected"
    }

    world
    |> apply_local_tender(tax, "#{source}_tax", day, opts)
    |> Map.update(:sales_tax_liability, tax, &Float.round(&1 + tax, 2))
    |> Map.update(:tax_history, [entry], &(&1 ++ [entry]))
  end

  def apply_local_sales_tax(world, _taxable_amount, _source, _day, _opts), do: world

  def sales_tax_for(world, taxable_amount) when taxable_amount > 0 do
    Float.round(taxable_amount * get(world, :sales_tax_rate, 0.0), 2)
  end

  def sales_tax_for(_world, _taxable_amount), do: 0.0

  def apply_transaction_costs(world, revenue, source, day, opts) do
    transaction_count = Keyword.get(opts, :transaction_count, 1)
    shipped_orders = Keyword.get(opts, :shipped_orders, 0)
    marketplace_fee_rate = Keyword.get(opts, :marketplace_fee_rate, 0.0)
    marketplace_platform = Keyword.get(opts, :marketplace_platform, nil)
    processing_fee = processing_fee_for(world, revenue, transaction_count)
    shipping_cost = shipping_label_cost(world, shipped_orders)
    marketplace_fee = marketplace_fee_for(revenue, marketplace_fee_rate)
    total_cost = Float.round(processing_fee + shipping_cost + marketplace_fee, 2)

    if total_cost > 0.0 do
      entry = %{
        day: day,
        source: source,
        marketplace_platform: marketplace_platform,
        revenue: Float.round(revenue, 2),
        transaction_count: transaction_count,
        shipped_orders: shipped_orders,
        processing_fee: processing_fee,
        shipping_label_cost: shipping_cost,
        marketplace_fee: marketplace_fee,
        total_cost: total_cost
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - total_cost, 2))
      |> Map.update(:transaction_cost_history, [entry], &(&1 ++ [entry]))
    else
      world
    end
  end

  def apply_local_transaction_costs(world, revenue, source, day, opts) do
    cash_rate = Keyword.get(opts, :cash_rate, get(world, :local_cash_tender_rate, 0.32))
    card_revenue = card_tender_amount(revenue, cash_rate)
    transaction_count = Keyword.get(opts, :transaction_count, 1)
    card_transaction_count = card_transaction_count(transaction_count, cash_rate, card_revenue)

    opts =
      opts
      |> Keyword.put(:transaction_count, card_transaction_count)
      |> Keyword.delete(:cash_rate)

    apply_transaction_costs(world, card_revenue, source, day, opts)
  end

  def apply_local_tender(world, amount, source, day, opts \\ [])

  def apply_local_tender(world, amount, source, day, opts) when amount > 0 do
    cash_rate = Keyword.get(opts, :cash_rate, get(world, :local_cash_tender_rate, 0.32))
    cash_amount = cash_tender_amount(amount, cash_rate)
    card_amount = Float.round(amount - cash_amount, 2)

    entry = %{
      day: day,
      type: "tender_split",
      source: source,
      amount: Float.round(amount, 2),
      cash_amount: cash_amount,
      card_amount: card_amount,
      cash_rate: cash_rate
    }

    world
    |> Map.update!(:cash_drawer_balance, &Float.round(&1 + cash_amount, 2))
    |> Map.update!(:bank_balance, &Float.round(&1 + card_amount, 2))
    |> Map.update(:cash_handling_history, [entry], &(&1 ++ [entry]))
  end

  def apply_local_tender(world, _amount, _source, _day, _opts), do: world

  def apply_cash_reconciliation({world, revenue}, day) do
    {apply_cash_reconciliation(world, day), revenue}
  end

  def apply_cash_reconciliation(world, day) do
    already_reconciled? =
      world
      |> get(:cash_handling_history, [])
      |> Enum.any?(&(get(&1, :type) == "cash_reconciliation" and get(&1, :day) == day))

    cash_tender_total = cash_tender_total_for_day(world, day)

    cond do
      already_reconciled? ->
        world

      cash_tender_total <= 0.0 ->
        world

      true ->
        over_short = cash_reconciliation_delta(world, day, cash_tender_total)
        expected_cash = get(world, :cash_drawer_balance, 0.0)
        actual_cash = Float.round(max(0.0, expected_cash + over_short), 2)
        over_short = Float.round(actual_cash - expected_cash, 2)

        entry = %{
          day: day,
          type: "cash_reconciliation",
          source: "daily_close",
          expected_cash: Float.round(expected_cash, 2),
          actual_cash: actual_cash,
          over_short_amount: over_short,
          shortage_amount: if(over_short < 0, do: Float.round(abs(over_short), 2), else: 0.0),
          overage_amount: if(over_short > 0, do: over_short, else: 0.0),
          tender_cash_total: cash_tender_total,
          transaction_count: cash_transaction_count_for_day(world, day),
          fatigue: get(get(world, :operations, %{}), :fatigue, 0),
          loss_prevention_score: get(world, :loss_prevention_score, 0)
        }

        world
        |> Map.put(:cash_drawer_balance, actual_cash)
        |> Map.update(:cash_handling_history, [entry], &(&1 ++ [entry]))
    end
  end

  defp cash_tender_total_for_day(world, day) do
    world
    |> get(:cash_handling_history, [])
    |> Enum.filter(&(get(&1, :type) == "tender_split" and get(&1, :day) == day))
    |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :cash_amount, 0.0) end)
    |> Float.round(2)
  end

  defp cash_transaction_count_for_day(world, day) do
    world
    |> get(:cash_handling_history, [])
    |> Enum.count(&(get(&1, :type) == "tender_split" and get(&1, :day) == day))
  end

  defp cash_reconciliation_delta(world, day, cash_tender_total) do
    seed = get(world, :seed, 1)
    fatigue = get(get(world, :operations, %{}), :fatigue, 0)
    backlog_count = length(get(get(world, :operations, %{}), :backlog_tasks, []))
    prevention_score = get(world, :loss_prevention_score, 0)

    magnitude =
      cash_tender_total * 0.006 + fatigue * 0.35 + backlog_count * 0.25 -
        prevention_score * 0.03

    magnitude =
      magnitude
      |> max(0.25)
      |> min(35.0)
      |> Float.round(2)

    if :erlang.phash2({seed, day, :cash_reconciliation}, 100) < 68 do
      -magnitude
    else
      magnitude
    end
  end

  defp cash_tender_amount(amount, cash_rate) when amount > 0 do
    Float.round(amount * cash_rate, 2)
  end

  defp cash_tender_amount(_amount, _cash_rate), do: 0.0

  defp card_tender_amount(amount, cash_rate) when amount > 0 do
    Float.round(amount - cash_tender_amount(amount, cash_rate), 2)
  end

  defp card_tender_amount(_amount, _cash_rate), do: 0.0

  defp card_transaction_count(_transaction_count, _cash_rate, card_revenue)
       when card_revenue <= 0.0,
       do: 0

  defp card_transaction_count(transaction_count, cash_rate, _card_revenue) do
    transaction_count
    |> Kernel.*(1.0 - cash_rate)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  defp processing_fee_for(_world, revenue, _transaction_count) when revenue <= 0.0, do: 0.0

  defp processing_fee_for(world, revenue, transaction_count) do
    rate = get(world, :payment_processing_rate, 0.029)
    fixed_fee = get(world, :payment_processing_fixed_fee, 0.3)
    Float.round(revenue * rate + max(transaction_count, 0) * fixed_fee, 2)
  end

  def marketplace_fee_for(revenue, rate) when revenue > 0.0 do
    Float.round(revenue * rate, 2)
  end

  def marketplace_fee_for(_revenue, _rate), do: 0.0

  def shipping_label_cost(_world, shipped_orders) when shipped_orders <= 0, do: 0.0

  def shipping_label_cost(world, shipped_orders) do
    Float.round(shipped_orders * get(world, :online_shipping_label_cost, 4.25), 2)
  end

  def maybe_remit_sales_tax(world, day, status) do
    liability = get(world, :sales_tax_liability, 0.0)

    if liability > 0.0 and (rem(day, 7) == 0 or status == "complete") do
      entry = %{
        day: day,
        source: "sales_tax_remittance",
        tax_remitted: Float.round(liability, 2),
        type: "remitted"
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - liability, 2))
      |> Map.put(:sales_tax_liability, 0.0)
      |> Map.update(:tax_history, [entry], &(&1 ++ [entry]))
    else
      world
    end
  end

  defp apply_credit_line_action(world, "draw", amount) do
    world
    |> Map.update!(:bank_balance, &Float.round(&1 + amount, 2))
    |> Map.update(:credit_line_balance, amount, &Float.round(&1 + amount, 2))
  end

  defp apply_credit_line_action(world, "repay", amount) do
    world
    |> Map.update!(:bank_balance, &Float.round(&1 - amount, 2))
    |> Map.update(:credit_line_balance, 0.0, &Float.round(max(0.0, &1 - amount), 2))
  end

  defp credit_line_balance_after(world, "draw", amount) do
    Float.round(get(world, :credit_line_balance, 0.0) + amount, 2)
  end

  defp credit_line_balance_after(world, "repay", amount) do
    Float.round(max(0.0, get(world, :credit_line_balance, 0.0) - amount), 2)
  end

  def apply_credit_line_interest(world, day) do
    balance = get(world, :credit_line_balance, 0.0)

    already_accrued? =
      world
      |> get(:debt_history, [])
      |> Enum.any?(&(get(&1, :day, nil) == day and get(&1, :type, nil) == "interest"))

    if balance > 0.0 and not already_accrued? do
      apr = get(world, :credit_line_apr, 0.18)
      interest = Float.round(balance * apr / 365, 2)

      if interest > 0.0 do
        entry = %{
          day: day,
          action: "interest",
          amount: interest,
          apr: apr,
          balance_before: Float.round(balance, 2),
          balance_after: Float.round(balance + interest, 2),
          type: "interest"
        }

        world
        |> Map.update(:credit_line_balance, interest, &Float.round(&1 + interest, 2))
        |> Map.update(:debt_history, [entry], &(&1 ++ [entry]))
      else
        world
      end
    else
      world
    end
  end

  def apply_daily_overhead(world, day) do
    already_recorded? =
      world
      |> get(:overhead_history, [])
      |> Enum.any?(&(get(&1, :day, nil) == day))

    if already_recorded? do
      world
    else
      rent = Float.round(get(world, :daily_rent, 125.0), 2)
      utilities = Float.round(get(world, :daily_utilities, 22.5), 2)
      insurance = Float.round(get(world, :daily_insurance, 7.5), 2)
      total = Float.round(rent + utilities + insurance, 2)

      entry = %{
        day: day,
        rent: rent,
        utilities: utilities,
        insurance: insurance,
        total: total,
        type: "fixed_overhead"
      }

      world
      |> Map.update!(:bank_balance, &Float.round(&1 - total, 2))
      |> Map.update(:overhead_history, [entry], &(&1 ++ [entry]))
    end
  end
end
