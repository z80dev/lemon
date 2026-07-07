defmodule LemonSim.Examples.TcgShop.Updaters.Staffing do
  @moduledoc false

  alias LemonSim.Kernel.State

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_schedule_staff_shift(%State{} = state, event) do
    role = get(event.payload, "role")
    hours = as_float(get(event.payload, "hours", 0.0))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_staff_role(role),
         :ok <- ensure_positive(hours),
         :ok <- ensure_staff_shift_hours(hours) do
      day = get(state.world, :day_number, 1)
      hourly_wage = staff_role_wage(role)
      labor_cost = Float.round(hours * hourly_wage, 2)

      case ensure_cash(state.world, labor_cost) do
        :ok ->
          operations = get(state.world, :operations, default_operations())
          current_backlog = get(operations, :backlog_tasks, [])
          backlog_cleared = min(length(current_backlog), trunc(hours / 3))
          fatigue_relief = if(hours >= 4.0, do: 1, else: 0)

          entry = %{
            day: day,
            role: role,
            hours: Float.round(hours, 2),
            hourly_wage: hourly_wage,
            labor_cost: labor_cost,
            backlog_cleared: backlog_cleared,
            fatigue_relief: fatigue_relief,
            type: "scheduled_shift"
          }

          next =
            state
            |> State.update_world(fn world ->
              world
              |> Map.update!(:bank_balance, &Float.round(&1 - labor_cost, 2))
              |> Map.update(:staffing_history, [entry], &(&1 ++ [entry]))
              |> update_in([:operations], fn operations ->
                operations = operations || default_operations()

                operations
                |> Map.update(:scheduled_staff_hours, hours, &Float.round(&1 + hours, 2))
                |> Map.update(
                  :scheduled_staff_hours_remaining,
                  hours,
                  &Float.round(&1 + hours, 2)
                )
                |> Map.update(:scheduled_staff_cost, labor_cost, &Float.round(&1 + labor_cost, 2))
                |> Map.update(:fatigue, 0, &max(0, &1 - fatigue_relief))
                |> Map.update(:backlog_tasks, [], &Enum.drop(&1, backlog_cleared))
              end)
            end)
            |> State.append_event(event)

          {:ok, next, {:decide, "scheduled #{hours} hours of #{role} coverage"}}

        {:error, reason} ->
          reject(state, event, reason)
      end
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_staff_role(role) do
    if role in ["sales_floor", "sorting", "event_judge", "online_fulfillment"],
      do: :ok,
      else: {:error, :invalid_staff_role}
  end

  defp ensure_staff_shift_hours(hours) do
    if hours <= 10,
      do: :ok,
      else: {:error, :staff_shift_too_long}
  end

  defp staff_role_wage("sales_floor"), do: 17.0
  defp staff_role_wage("sorting"), do: 16.0
  defp staff_role_wage("event_judge"), do: 24.0
  defp staff_role_wage("online_fulfillment"), do: 18.5
  defp staff_role_wage(_role), do: 18.0

  def apply_daily_payroll(world, day) do
    already_paid? =
      world
      |> get(:payroll_history, [])
      |> Enum.any?(&(get(&1, :day, nil) == day))

    if already_paid? do
      world
    else
      operations = get(world, :operations, default_operations())
      wage = get(operations, :regular_hourly_wage, 18.0)

      regular_hours =
        world
        |> get(:operations_history, [])
        |> Enum.filter(&(get(&1, :day, nil) == day))
        |> Enum.reduce(0.0, fn entry, acc -> acc + get(entry, :regular_hours, 0.0) end)
        |> Float.round(2)

      paid_hours =
        if regular_hours > 0.0 do
          Float.round(max(regular_hours, 4.0), 2)
        else
          0.0
        end

      payroll_cost = Float.round(paid_hours * wage, 2)

      if payroll_cost > 0.0 do
        entry = %{
          day: day,
          regular_hours_used: regular_hours,
          paid_hours: paid_hours,
          hourly_wage: wage,
          payroll_cost: payroll_cost
        }

        updated_operations =
          operations
          |> Map.update(
            :cumulative_regular_payroll,
            payroll_cost,
            &Float.round(&1 + payroll_cost, 2)
          )

        world
        |> Map.put(:operations, updated_operations)
        |> Map.update!(:bank_balance, &Float.round(&1 - payroll_cost, 2))
        |> Map.update(:payroll_history, [entry], &(&1 ++ [entry]))
      else
        world
      end
    end
  end

  def consume_staff_hours(world, hours, action) do
    day = get(world, :day_number, 1)
    operations = get(world, :operations, default_operations())
    remaining = get(operations, :staff_hours_remaining, 0.0)
    scheduled_remaining = get(operations, :scheduled_staff_hours_remaining, 0.0)
    regular_hours = Float.round(min(hours, remaining), 2)
    scheduled_hours = Float.round(min(max(0.0, hours - regular_hours), scheduled_remaining), 2)
    overtime_hours = Float.round(max(0.0, hours - regular_hours - scheduled_hours), 2)
    overtime_cost = Float.round(overtime_hours * 28.0, 2)

    entry = %{
      day: day,
      action: action,
      staff_hours: hours,
      regular_hours: regular_hours,
      scheduled_hours: scheduled_hours,
      overtime_hours: overtime_hours,
      overtime_cost: overtime_cost
    }

    backlog =
      if overtime_hours >= 1.0 do
        [
          %{
            day: day,
            source: action,
            task: "follow up after overtime-heavy #{String.replace(action, "_", " ")}"
          }
        ]
      else
        []
      end

    updated_operations =
      operations
      |> Map.put(:staff_hours_remaining, Float.round(max(0.0, remaining - hours), 2))
      |> Map.put(
        :scheduled_staff_hours_remaining,
        Float.round(max(0.0, scheduled_remaining - max(0.0, hours - regular_hours)), 2)
      )
      |> Map.update(
        :cumulative_overtime_hours,
        overtime_hours,
        &Float.round(&1 + overtime_hours, 2)
      )
      |> Map.update(:cumulative_overtime_cost, overtime_cost, &Float.round(&1 + overtime_cost, 2))
      |> Map.update(
        :fatigue,
        fatigue_delta(overtime_hours),
        &min(10, &1 + fatigue_delta(overtime_hours))
      )
      |> Map.update(:backlog_tasks, backlog, &(&1 ++ backlog))

    world
    |> Map.put(:operations, updated_operations)
    |> Map.update!(:bank_balance, &Float.round(&1 - overtime_cost, 2))
    |> Map.update(:operations_history, [entry], &(&1 ++ [entry]))
  end

  def reset_staff_day(world) do
    operations = get(world, :operations, default_operations())
    daily_hours = get(operations, :daily_staff_hours, 10.0)

    backlog_tasks =
      operations
      |> get(:backlog_tasks, [])
      |> Enum.take(-6)

    updated_operations =
      operations
      |> Map.put(:staff_hours_remaining, daily_hours)
      |> Map.put(:scheduled_staff_hours, 0.0)
      |> Map.put(:scheduled_staff_hours_remaining, 0.0)
      |> Map.put(:scheduled_staff_cost, 0.0)
      |> Map.put(:fatigue, max(0, get(operations, :fatigue, 0) - 1))
      |> Map.put(:backlog_tasks, backlog_tasks)

    Map.put(world, :operations, updated_operations)
  end

  def default_operations do
    %{
      daily_staff_hours: 10.0,
      staff_hours_remaining: 10.0,
      regular_hourly_wage: 18.0,
      scheduled_staff_hours: 0.0,
      scheduled_staff_hours_remaining: 0.0,
      scheduled_staff_cost: 0.0,
      cumulative_regular_payroll: 0.0,
      cumulative_overtime_hours: 0.0,
      cumulative_overtime_cost: 0.0,
      fatigue: 0,
      backlog_tasks: []
    }
  end

  defp fatigue_delta(overtime_hours) when overtime_hours >= 2.0, do: 2
  defp fatigue_delta(overtime_hours) when overtime_hours > 0.0, do: 1
  defp fatigue_delta(_), do: 0
end
