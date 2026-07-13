defmodule LemonSim.Examples.Werewolf.Updaters.Chat do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.Updaters.Discussion
  alias LemonSim.Examples.Werewolf.Updaters.Items

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_anonymous_message(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    message = fetch(event.payload, :message, "message")
    players = get(state.world, :players, %{})
    player_items = get(state.world, :player_items, %{})
    current_items = Map.get(player_items, player_id, [])

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["day_discussion", "runoff_discussion"]),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_text(message),
         true <- Items.has_item?(current_items, "anonymous_letter") do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: "Anonymous", statement: message, type: "anonymous"}
      new_transcript = transcript ++ [new_entry]

      new_items = Items.remove_first_item(current_items, "anonymous_letter")
      new_player_items = Map.put(player_items, player_id, new_items)

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
        reject_action(state, event, player_id, :item_not_owned)

      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end
end
