defmodule LemonSim.Examples.Werewolf.Updaters.Discussion do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.Roles
  alias LemonSim.Examples.Werewolf.Updaters.Voting

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["day_discussion", "runoff_discussion"]),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_text(statement) do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: player_id, statement: statement}
      new_transcript = transcript ++ [new_entry]

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            discussion_turn_count: discussion_turn_count(state.world) + 1
          })
        )
        |> State.append_event(event)

      advance_day_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  def advance_day_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)
    discussion_round = get(state.world, :discussion_round, 1)
    discussion_round_limit = get(state.world, :discussion_round_limit, 1)
    day_number = get(state.world, :day_number, 1)
    players = get(state.world, :players, %{})
    phase = get(state.world, :phase)

    if discussion_turn_limit_reached?(state.world) do
      if phase == "runoff_discussion" do
        Voting.transition_to_runoff_voting(state)
      else
        Voting.transition_to_voting(state)
      end
    else
      case next_in_order(turn_order, active_actor_id) do
        nil ->
          if discussion_round < discussion_round_limit do
            next_round = discussion_round + 1
            next_order = Roles.discussion_turn_order(players, day_number, next_round)
            next_actor = List.first(next_order)

            next_state =
              State.put_world(
                state,
                world_updates(state.world, %{
                  discussion_round: next_round,
                  turn_order: next_order,
                  active_actor_id: next_actor
                })
              )

            {:ok, next_state, {:decide, "#{next_actor} discussion round #{next_round}"}}
          else
            if phase == "runoff_discussion" do
              Voting.transition_to_runoff_voting(state)
            else
              Voting.transition_to_voting(state)
            end
          end

        next_actor ->
          next_state =
            State.put_world(
              state,
              world_updates(state.world, %{active_actor_id: next_actor})
            )

          {:ok, next_state, {:decide, "#{next_actor} discussion turn"}}
      end
    end
  end

  def apply_make_accusation(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    reason = fetch(event.payload, :reason, "reason")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["day_discussion", "runoff_discussion"]),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id),
         :ok <- ensure_text(reason) do
      transcript = get(state.world, :discussion_transcript, [])

      new_entry = %{
        player: player_id,
        statement: reason,
        reason: reason,
        type: "accusation",
        target: target_id
      }

      new_transcript = transcript ++ [new_entry]

      turn_order = get(state.world, :turn_order, [])
      new_turn_order = prioritize_accusation_response(turn_order, player_id, target_id)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            discussion_turn_count: discussion_turn_count(state.world) + 1,
            turn_order: new_turn_order
          })
        )
        |> State.append_event(event)

      advance_day_discussion_turn(next_state)
    else
      {:error, reason_atom} ->
        reject_action(state, event, player_id, reason_atom)
    end
  end

  def discussion_turn_count(world) do
    get(world, :discussion_turn_count, length(get(world, :discussion_transcript, [])))
  end

  defp discussion_turn_limit_reached?(world) do
    turn_order = get(world, :turn_order, [])
    round_limit = get(world, :discussion_round_limit, 0)

    turn_limit =
      get(world, :discussion_turn_limit, discussion_turn_limit(turn_order, round_limit))

    turn_limit > 0 and discussion_turn_count(world) >= turn_limit
  end

  def discussion_turn_limit(turn_order, round_limit) do
    length(turn_order) * max(round_limit, 0)
  end

  # Accusations can pull one future speaker forward, but they must not rewind the
  # round back to someone who already spoke or create duplicate turns.

  defp prioritize_accusation_response(turn_order, current_player_id, target_id) do
    case Enum.find_index(turn_order, &(&1 == current_player_id)) do
      nil ->
        turn_order

      current_idx ->
        next_idx = current_idx + 1

        case Enum.find_index(turn_order, &(&1 == target_id)) do
          nil ->
            turn_order

          target_idx when target_idx <= current_idx ->
            turn_order

          target_idx when target_idx == next_idx ->
            turn_order

          target_idx ->
            turn_order
            |> List.delete_at(target_idx)
            |> List.insert_at(next_idx, target_id)
        end
    end
  end
end
