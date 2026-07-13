defmodule LemonSim.Examples.Werewolf.Updaters.VillageEvents do
  @moduledoc false

  alias LemonSim.Examples.Werewolf.RulesConfig

  def maybe_generate_village_event(day_number, world \\ %{}) do
    if RulesConfig.enabled?(world, :village_events) and day_number > 1 and
         :rand.uniform() < 0.5 do
      events = [
        {"stranger_arrives",
         "A mysterious stranger was seen passing through the village at dawn. No one recognizes them."},
        {"supply_raid", "The village storehouse was raided overnight! Supplies are missing."},
        {"blizzard", "A fierce blizzard is rolling in. The village must make decisions quickly."},
        {"festival",
         "Today is the village harvest festival! Spirits are high and people are willing to talk."},
        {"omen",
         "A black crow was found dead on the village well this morning. Some say it's a dark omen."},
        {"missing_livestock",
         "Several sheep were found dead near the edge of the village. Claw marks cover the fence."}
      ]

      Enum.random(events)
    else
      nil
    end
  end

  def adjust_discussion_round_limit(base_limit, nil), do: base_limit

  def adjust_discussion_round_limit(base_limit, {event_type, _description}) do
    adjust_discussion_round_limit(base_limit, event_type)
  end

  def adjust_discussion_round_limit(base_limit, event) when is_map(event) do
    adjust_discussion_round_limit(base_limit, Map.get(event, :type) || Map.get(event, "type"))
  end

  def adjust_discussion_round_limit(base_limit, event_type) do
    case event_type do
      "blizzard" -> max(1, base_limit - 1)
      "festival" -> base_limit + 1
      _ -> base_limit
    end
  end
end
