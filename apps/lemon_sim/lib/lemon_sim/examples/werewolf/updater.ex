defmodule LemonSim.Examples.Werewolf.Updater do
  @moduledoc false

  @behaviour LemonSim.Kernel.Updater

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers, except: [maybe_store_thought: 2]

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.Events
  alias LemonSim.Examples.Werewolf.Updaters.Chat
  alias LemonSim.Examples.Werewolf.Updaters.Discussion
  alias LemonSim.Examples.Werewolf.Updaters.Elimination
  alias LemonSim.Examples.Werewolf.Updaters.Meetings
  alias LemonSim.Examples.Werewolf.Updaters.NightActions
  alias LemonSim.Examples.Werewolf.Updaters.Voting
  alias LemonSim.Examples.Werewolf.Updaters.WolfChat

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    # Extract and store thought if present
    state = maybe_store_thought(state, event)

    case event.kind do
      "choose_victim" -> NightActions.apply_choose_victim(state, event)
      "investigate_player" -> NightActions.apply_investigate_player(state, event)
      "protect_player" -> NightActions.apply_protect_player(state, event)
      "sleep" -> NightActions.apply_sleep(state, event)
      "night_wander" -> NightActions.apply_night_wander(state, event)
      "make_statement" -> Discussion.apply_make_statement(state, event)
      "cast_vote" -> Voting.apply_cast_vote(state, event)
      "make_last_words" -> Elimination.apply_make_last_words(state, event)
      "wolf_chat" -> WolfChat.apply_wolf_chat(state, event)
      "make_accusation" -> Discussion.apply_make_accusation(state, event)
      "request_meeting" -> Meetings.apply_request_meeting(state, event)
      "meeting_message" -> Meetings.apply_meeting_message(state, event)
      "use_item" -> NightActions.apply_use_item(state, event)
      "anonymous_message" -> Chat.apply_anonymous_message(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  defp maybe_store_thought(state, event) do
    thought = Map.get(event.payload, "thought") || Map.get(event.payload, :thought)
    player_id = Map.get(event.payload, "player_id") || Map.get(event.payload, :player_id)

    if is_binary(thought) and thought != "" and is_binary(player_id) do
      journals = get(state.world, :journals, %{})
      player_journal = Map.get(journals, player_id, [])

      entry = %{
        day: get(state.world, :day_number, 1),
        phase: get(state.world, :phase),
        thought: thought
      }

      new_journals = Map.put(journals, player_id, player_journal ++ [entry])
      State.put_world(state, world_updates(state.world, %{journals: new_journals}))
    else
      state
    end
  end
end
