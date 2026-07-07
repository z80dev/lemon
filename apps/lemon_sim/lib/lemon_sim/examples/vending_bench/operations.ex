defmodule LemonSim.Examples.VendingBench.Operations do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.VendingBench.DayRollover

  import LemonSim.Examples.VendingBench.Support

  def apply_support_event(state, event, time_cost) do
    state =
      state
      |> State.update_world(fn world ->
        time = get(world, :time_minutes, 540) + time_cost
        Map.put(world, :time_minutes, time)
      end)
      |> State.append_event(event)

    DayRollover.maybe_rollover(state)
  end

  def apply_supplier_research(state, event) do
    query = get(event.payload, :query, "")
    result_count = get(event.payload, :result_count, 0)

    state =
      state
      |> State.update_world(fn world ->
        history = get(world, :supplier_research_history, [])

        research_entry = %{
          query: query,
          result_count: result_count,
          day: get(world, :day_number, 1),
          time: get(world, :time_minutes, 540)
        }

        world
        |> Map.put(:supplier_research_history, history ++ [research_entry])
        |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 15)
      end)
      |> State.append_event(event)

    DayRollover.maybe_rollover(state)
  end

  def apply_market_research(state, event) do
    query = get(event.payload, :query, "")
    result_count = get(event.payload, :result_count, 0)

    state =
      state
      |> State.update_world(fn world ->
        history = get(world, :market_research_history, [])

        entry = %{
          query: query,
          result_count: result_count,
          day: get(world, :day_number, 1),
          time: get(world, :time_minutes, 540)
        }

        world
        |> Map.put(:market_research_history, history ++ [entry])
        |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 15)
      end)
      |> State.append_event(event)

    DayRollover.maybe_rollover(state)
  end

  def apply_reminder_created(state, event) do
    reminder_id = get(event.payload, :reminder_id, "")
    day = get(event.payload, :day, 1)
    text = get(event.payload, :text, "")

    state =
      state
      |> State.update_world(fn world ->
        reminders = get(world, :reminders, [])

        reminder = %{
          id: reminder_id,
          day: day,
          text: text,
          status: "open",
          created_day: get(world, :day_number, 1),
          created_time: get(world, :time_minutes, 540)
        }

        world
        |> Map.put(:reminders, reminders ++ [reminder])
        |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 5)
      end)
      |> State.append_event(event)

    DayRollover.maybe_rollover(state)
  end

  def apply_reminder_completed(state, event) do
    reminder_id = get(event.payload, :reminder_id, "")

    state =
      state
      |> State.update_world(fn world ->
        reminders = get(world, :reminders, [])

        reminders =
          Enum.map(reminders, fn reminder ->
            if get(reminder, :id) == reminder_id do
              reminder
              |> Map.put(:status, "done")
              |> Map.put(:completed_day, get(world, :day_number, 1))
              |> Map.put(:completed_time, get(world, :time_minutes, 540))
            else
              reminder
            end
          end)

        world
        |> Map.put(:reminders, reminders)
        |> Map.put(:time_minutes, get(world, :time_minutes, 540) + 3)
      end)
      |> State.append_event(event)

    DayRollover.maybe_rollover(state)
  end
end
