defmodule LemonSim.Examples.Werewolf.Updaters.Chat do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.Updaters.Discussion
  alias LemonSim.Examples.Werewolf.Updaters.Items

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_anonymous_message(%State{} = state, event) do
    message = fetch(event.payload, :message, "message")
    phase = get(state.world, :phase)

    with :ok <- ensure_in_progress(state.world),
         true <- phase in ["day_discussion", "runoff_discussion"] do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: "Anonymous", statement: message, type: "anonymous"}
      new_transcript = transcript ++ [new_entry]

      active_actor = get(state.world, :active_actor_id)
      player_items = get(state.world, :player_items, %{})
      current_items = Map.get(player_items, active_actor, [])
      new_items = Items.remove_first_item(current_items, "anonymous_letter")
      new_player_items = Map.put(player_items, active_actor, new_items)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            player_items: new_player_items,
            discussion_turn_count: Discussion.discussion_turn_count(state.world) + 1
          })
        )
        |> State.append_event(event)

      Discussion.advance_day_discussion_turn(next_state)
    else
      false ->
        reject_action(state, event, "Anonymous", :wrong_phase)

      {:error, reason} ->
        reject_action(state, event, "Anonymous", reason)
    end
  end
end
