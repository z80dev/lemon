defmodule LemonSim.Examples.TcgShop.Updaters.Promotions do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Customers
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_run_promotion(%State{} = state, event) do
    franchise = get(event.payload, "franchise")
    channel = get(event.payload, "channel", "social_ads")
    budget = as_float(get(event.payload, "budget", 0.0))
    duration_days = as_int(get(event.payload, "duration_days", 1))

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_franchise(franchise),
         :ok <- ensure_promotion_channel(channel),
         :ok <- ensure_minimum(budget, 25.0),
         :ok <- ensure_duration(duration_days),
         :ok <- ensure_cash(state.world, budget) do
      day = get(state.world, :day_number, 1)
      promotion = build_promotion(franchise, channel, budget, duration_days, day, state.world)

      next =
        state
        |> State.update_world(fn world ->
          world
          |> Map.update!(:bank_balance, &Float.round(&1 - budget, 2))
          |> Map.update(:active_promotions, [promotion], &(&1 ++ [promotion]))
          |> Map.update(:promotion_history, [promotion], &(&1 ++ [promotion]))
          |> Customers.update_customer_segment(
            Customers.customer_segment_for_franchise(franchise),
            %{
              loyalty_delta: 1,
              satisfaction_delta: 1,
              visits_delta: 0,
              spend_delta: 0.0,
              reason: "promotion"
            }
          )
          |> Staffing.consume_staff_hours(
            Float.round(0.45 + duration_days * 0.12, 2),
            "promotion"
          )
        end)
        |> State.append_event(event)

      {:ok, next,
       {:decide,
        "started #{channel} promotion for #{franchise} through day #{promotion.ends_day}"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_promotion_channel(channel) do
    if channel in ["social_ads", "email_list", "community_flyers", "creator_sponsorship"],
      do: :ok,
      else: {:error, :invalid_promotion_channel}
  end

  defp ensure_duration(duration_days) do
    if duration_days >= 1 and duration_days <= 7,
      do: :ok,
      else: {:error, :invalid_duration}
  end

  defp build_promotion(franchise, channel, budget, duration_days, day, world) do
    pressure =
      world
      |> get(:competitive_position, %{})
      |> get(:competitor_pressure, 0.0)

    lift =
      budget
      |> Kernel./(900.0)
      |> Kernel.*(promotion_channel_lift(channel))
      |> Kernel.-(pressure / 60)
      |> clamp_float(0.05, 0.55)
      |> Float.round(2)

    %{
      id: "promo_#{day}_#{String.replace(franchise, ~r/[^A-Za-z0-9]+/, "_")}_#{channel}",
      day: day,
      franchise: franchise,
      channel: channel,
      budget: Float.round(budget, 2),
      duration_days: duration_days,
      ends_day: day + duration_days,
      demand_lift: lift,
      status: "active"
    }
  end

  defp promotion_channel_lift("email_list"), do: 1.25
  defp promotion_channel_lift("community_flyers"), do: 0.85
  defp promotion_channel_lift("creator_sponsorship"), do: 1.45
  defp promotion_channel_lift(_), do: 1.0

  def expire_promotions(world, day) do
    active =
      world
      |> get(:active_promotions, [])
      |> Enum.filter(&(get(&1, :ends_day, 0) >= day))

    Map.put(world, :active_promotions, active)
  end

  def active_promotion_for(world, franchise, day) do
    world
    |> get(:active_promotions, [])
    |> Enum.filter(fn promotion ->
      get(promotion, :franchise) == franchise and get(promotion, :day, 0) <= day and
        get(promotion, :ends_day, 0) >= day
    end)
    |> Enum.max_by(&get(&1, :demand_lift, 0.0), fn -> nil end)
  end

  def promotion_multiplier(nil), do: 1.0

  def promotion_multiplier(promotion),
    do: Float.round(1.0 + get(promotion, :demand_lift, 0.0), 2)
end
