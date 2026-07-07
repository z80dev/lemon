defmodule LemonSim.Examples.TcgShop.Updaters.Memberships do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_sell_memberships(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    count = as_int(get(event.payload, "count", 0))
    fee = as_float(get(event.payload, "fee", 0.0))
    duration_days = as_int(get(event.payload, "duration_days", 0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_positive(count),
         :ok <- ensure_minimum(fee, 5.0),
         :ok <- ensure_membership_duration(duration_days) do
      day = get(state.world, :day_number, 1)
      collected = Float.round(count * fee, 2)
      segment_id = Customers.customer_segment_for_franchise(franchise)

      batch = %{
        id: membership_batch_id(state.world, day, franchise),
        day: day,
        franchise: franchise,
        segment_id: segment_id,
        member_count: count,
        fee: Float.round(fee, 2),
        duration_days: duration_days,
        remaining_days: duration_days,
        collected: collected,
        remaining_value: collected,
        status: "active"
      }

      entry = Map.merge(batch, %{type: "sold"})

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Finance.apply_local_tender(collected, "membership_sale", day)
          |> Finance.apply_local_sales_tax(collected, "membership_sale", day)
          |> Finance.apply_local_transaction_costs(collected, "membership_sale", day,
            transaction_count: max(1, count)
          )
          |> Map.update(:active_memberships, [batch], &(&1 ++ [batch]))
          |> Map.update(:membership_liability, collected, &Float.round(&1 + collected, 2))
          |> Map.update(:membership_history, [entry], &(&1 ++ [entry]))
          |> Customers.update_customer_segment(segment_id, %{
            loyalty_delta: 3,
            satisfaction_delta: 2,
            visits_delta: count,
            spend_delta: collected,
            reason: "membership_sale"
          })
          |> Staffing.consume_staff_hours(Float.round(0.4 + count * 0.04, 2), "membership_sale")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "sold #{count} #{franchise} memberships"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_membership_duration(duration_days) do
    if duration_days >= 1 and duration_days <= 30,
      do: :ok,
      else: {:error, :invalid_membership_duration}
  end

  defp membership_batch_id(world, day, franchise) do
    next_number = length(get(world, :membership_history, [])) + 1
    slug = String.replace(franchise, ~r/[^A-Za-z0-9]+/, "_")
    "member_#{day}_#{slug}_#{next_number}"
  end

  def apply_membership_recognition(world, day) do
    {memberships, entries, recognized} =
      world
      |> get(:active_memberships, [])
      |> Enum.reduce({[], [], 0.0}, fn membership, {memberships_acc, entries_acc, total_acc} ->
        if get(membership, :status, "active") == "active" and
             get(membership, :remaining_days, 0) > 0 and
             get(membership, :remaining_value, 0.0) > 0.0 do
          remaining_days = max(1, get(membership, :remaining_days, 1))
          remaining_value = get(membership, :remaining_value, 0.0)
          recognition = Float.round(min(remaining_value, remaining_value / remaining_days), 2)
          next_remaining_value = Float.round(max(0.0, remaining_value - recognition), 2)
          next_remaining_days = max(0, remaining_days - 1)

          status =
            if next_remaining_days > 0 and next_remaining_value > 0.0,
              do: "active",
              else: "expired"

          updated =
            membership
            |> Map.put(:remaining_days, next_remaining_days)
            |> Map.put(:remaining_value, next_remaining_value)
            |> Map.put(:status, status)

          entry = %{
            id: get(membership, :id),
            day: day,
            franchise: get(membership, :franchise),
            segment_id: get(membership, :segment_id),
            member_count: get(membership, :member_count, 0),
            revenue_recognized: recognition,
            remaining_value: next_remaining_value,
            remaining_days: next_remaining_days,
            status: status,
            type: "recognized"
          }

          {memberships_acc ++ [updated], entries_acc ++ [entry], total_acc + recognition}
        else
          {memberships_acc ++ [membership], entries_acc, total_acc}
        end
      end)

    recognized = Float.round(recognized, 2)

    world
    |> Map.put(:active_memberships, memberships)
    |> Map.update(:membership_liability, 0.0, &Float.round(max(0.0, &1 - recognized), 2))
    |> Map.update(:membership_history, entries, &(&1 ++ entries))
  end

  def membership_demand_multiplier(world, segment_id) do
    members =
      world
      |> get(:active_memberships, [])
      |> Enum.filter(
        &(get(&1, :status, "active") == "active" and get(&1, :segment_id) == segment_id)
      )
      |> Enum.reduce(0, fn membership, acc -> acc + get(membership, :member_count, 0) end)

    (1.0 + min(members, 60) / 240)
    |> clamp_float(1.0, 1.25)
  end
end
