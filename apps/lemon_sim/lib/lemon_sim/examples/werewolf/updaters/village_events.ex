defmodule LemonSim.Examples.Werewolf.Updaters.VillageEvents do
  @moduledoc false

  alias LemonSim.Kernel.State

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def maybe_generate_village_event(day_number) do
    if day_number > 1 and :rand.uniform() < 0.5 do
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

  def apply_village_event_effects(state, nil), do: state

  def apply_village_event_effects(state, {event_type, _description}) do
    case event_type do
      "blizzard" ->
        current_limit = get(state.world, :discussion_round_limit, 2)
        new_limit = max(1, current_limit - 1)
        State.put_world(state, world_updates(state.world, %{discussion_round_limit: new_limit}))

      "festival" ->
        current_limit = get(state.world, :discussion_round_limit, 2)

        State.put_world(
          state,
          world_updates(state.world, %{discussion_round_limit: current_limit + 1})
        )

      _ ->
        state
    end
  end
end
