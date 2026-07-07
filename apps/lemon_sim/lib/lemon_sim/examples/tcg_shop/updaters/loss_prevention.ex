defmodule LemonSim.Examples.TcgShop.Updaters.LossPrevention do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_upgrade_loss_prevention(%State{} = state, event) do
    control = get(event.payload, "control")

    with :ok <- ensure_in_progress(state.world),
         {:ok, option} <- loss_prevention_option(control),
         :ok <- ensure_loss_prevention_not_installed(state.world, control),
         :ok <- ensure_cash(state.world, get(option, :cost, 0.0)) do
      day = get(state.world, :day_number, 1)
      cost = get(option, :cost, 0.0)
      protection = get(option, :protection, 0)

      entry = %{
        day: day,
        control: control,
        label: get(option, :label),
        cost: cost,
        protection_score: protection,
        type: "loss_prevention_upgrade"
      }

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - cost, 2))
          |> Map.update(:loss_prevention_score, protection, &min(80, &1 + protection))
          |> Map.update(:loss_prevention_history, [entry], &(&1 ++ [entry]))
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "installed #{control} loss-prevention control"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_loss_prevention_not_installed(world, control) do
    installed? =
      world
      |> get(:loss_prevention_history, [])
      |> Enum.any?(&(get(&1, :control) == control))

    if installed?,
      do: {:error, :loss_prevention_already_installed},
      else: :ok
  end

  defp loss_prevention_option("display_case_locks") do
    {:ok, %{label: "Locked display cases", cost: 220.0, protection: 18}}
  end

  defp loss_prevention_option("camera_system") do
    {:ok, %{label: "Camera system", cost: 650.0, protection: 28}}
  end

  defp loss_prevention_option("inventory_audit_process") do
    {:ok, %{label: "Inventory audit process", cost: 140.0, protection: 14}}
  end

  defp loss_prevention_option(_control), do: {:error, :invalid_loss_prevention_control}

  def apply_daily_shrinkage({world, revenue}, day) do
    {apply_daily_shrinkage(world, day), revenue}
  end

  def apply_daily_shrinkage(world, day) do
    catalog = get(world, :catalog, %{})
    operations = get(world, :operations, Staffing.default_operations())
    fatigue = get(operations, :fatigue, 0)
    backlog_count = length(get(operations, :backlog_tasks, []))
    prevention_score = get(world, :loss_prevention_score, 0)
    seed = get(world, :seed, 1)

    {inventory, entries} =
      world
      |> get(:inventory, %{})
      |> Enum.reduce({%{}, []}, fn {line_id, item}, {inventory_acc, entries_acc} ->
        on_hand = get(item, :on_hand, 0)
        risk = shrinkage_risk(on_hand, fatigue, backlog_count, prevention_score)

        if shrinkage_trigger?(seed, day, line_id, risk) do
          line = Map.get(catalog, line_id, %{})
          units = min(on_hand, max(1, div(on_hand, 25) + if(fatigue >= 8, do: 1, else: 0)))
          market_price = get(line, :market_price, get(item, :price, 0.0))

          entry = %{
            day: day,
            line_id: line_id,
            units: units,
            estimated_loss: Float.round(units * market_price * 0.65, 2),
            prevention_score: prevention_score,
            risk_score: risk,
            reason: shrinkage_reason(fatigue, backlog_count, prevention_score)
          }

          updated_item = Map.put(item, :on_hand, max(0, on_hand - units))
          {Map.put(inventory_acc, line_id, updated_item), entries_acc ++ [entry]}
        else
          {Map.put(inventory_acc, line_id, item), entries_acc}
        end
      end)

    if entries == [] do
      world
    else
      world
      |> Map.put(:inventory, inventory)
      |> Map.update(:shrinkage_history, entries, &(&1 ++ entries))
    end
  end

  defp shrinkage_risk(on_hand, _fatigue, _backlog_count, _prevention_score) when on_hand <= 0,
    do: 0

  defp shrinkage_risk(on_hand, fatigue, _backlog_count, prevention_score)
       when fatigue >= 8 and on_hand >= 40,
       do: max(0, 100 - prevention_score)

  defp shrinkage_risk(on_hand, fatigue, backlog_count, prevention_score) do
    max(0, 2 + fatigue * 2 + min(8, div(on_hand, 8)) + min(backlog_count, 5) - prevention_score)
  end

  defp shrinkage_trigger?(_seed, _day, _line_id, risk) when risk >= 100, do: true
  defp shrinkage_trigger?(_seed, _day, _line_id, risk) when risk <= 0, do: false

  defp shrinkage_trigger?(seed, day, line_id, risk) do
    :erlang.phash2({seed, day, line_id, :shrinkage}, 100) < risk
  end

  defp shrinkage_reason(fatigue, backlog_count, prevention_score) do
    cond do
      prevention_score >= 40 -> "loss prevention controls missed a high-risk incident"
      fatigue >= 8 -> "fatigued handling damaged inventory"
      backlog_count >= 4 -> "backlog delayed inventory cleanup"
      true -> "normal retail shrinkage"
    end
  end
end
