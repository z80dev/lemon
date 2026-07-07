defmodule LemonSim.Examples.DungeonCrawl.Updater do
  @moduledoc false

  @behaviour LemonSim.Kernel.Updater

  import LemonSim.Examples.Helpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.DungeonCrawl.Events
  alias LemonSim.Examples.DungeonCrawl.Updaters.Combat
  alias LemonSim.Examples.DungeonCrawl.Updaters.Items
  alias LemonSim.Examples.DungeonCrawl.Updaters.Turns

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "attack_requested" -> Combat.apply_attack(state, event)
      "ability_requested" -> Combat.apply_ability(state, event)
      "use_item_requested" -> Items.apply_use_item(state, event)
      "end_turn_requested" -> Turns.apply_end_turn(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end
end
