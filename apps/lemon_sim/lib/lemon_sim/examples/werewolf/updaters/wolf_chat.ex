defmodule LemonSim.Examples.Werewolf.Updaters.WolfChat do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.{Events, Roles}

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_wolf_chat(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    message = fetch(event.payload, :message, "message")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "wolf_discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "werewolf"),
         :ok <- ensure_text(message) do
      wolf_chat = get(state.world, :wolf_chat_transcript, [])
      wolf_chat_history = get(state.world, :wolf_chat_history, [])
      new_entry = %{day: get(state.world, :day_number, 1), player: player_id, message: message}
      new_chat = wolf_chat ++ [new_entry]
      new_history = wolf_chat_history ++ [new_entry]

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            wolf_chat_transcript: new_chat,
            wolf_chat_history: new_history
          })
        )
        |> State.append_event(event)

      advance_wolf_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_wolf_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All wolves have spoken; transition to night actions
        transition_to_night_actions(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} wolf chat"}}
    end
  end

  defp transition_to_night_actions(%State{} = state) do
    players = get(state.world, :players, %{})
    night_order = Roles.night_turn_order(players)
    first_actor = List.first(night_order)
    day_number = get(state.world, :day_number, 1)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "night",
          turn_order: night_order,
          active_actor_id: first_actor,
          night_actions: %{}
        })
      )
      |> State.append_event(Events.phase_changed("night", day_number))

    {:ok, next_state, {:decide, "#{first_actor} night action"}}
  end
end
