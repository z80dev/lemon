defmodule LemonSim.Examples.SpaceStation.Updater do
  @moduledoc false

  @behaviour LemonSim.Kernel.Updater

  import LemonSim.Examples.Helpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonSim.Examples.SpaceStation.Events
  alias LemonSim.Examples.SpaceStation.Updaters.Actions
  alias LemonSim.Examples.SpaceStation.Updaters.Discussion
  alias LemonSim.Examples.SpaceStation.Updaters.Voting
  alias LemonSim.Kernel.State

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    # Extract and store thought if present
    state = maybe_store_thought(state, event)

    case event.kind do
      "repair_system" -> Actions.apply_repair_system(state, event)
      "sabotage_system" -> Actions.apply_sabotage_system(state, event)
      "fake_repair" -> Actions.apply_fake_repair(state, event)
      "scan_player" -> Actions.apply_scan_player(state, event)
      "lock_room" -> Actions.apply_lock_room(state, event)
      "call_emergency_meeting" -> Actions.apply_call_emergency_meeting(state, event)
      "vent" -> Actions.apply_vent(state, event)
      "make_statement" -> Discussion.apply_make_statement(state, event)
      "ask_question" -> Discussion.apply_ask_question(state, event)
      "accuse" -> Discussion.apply_accuse(state, event)
      "cast_vote" -> Voting.apply_cast_vote(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end
end
