defmodule LemonSim.Examples.SpaceStation.Updaters.Discussion do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers
  import LemonSim.Examples.SpaceStation.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.SpaceStation.Roles
  alias LemonSim.Examples.SpaceStation.Updaters.Voting

  # -- Discussion: Make statement --

  def apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: player_id, statement: statement}
      new_transcript = transcript ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{discussion_transcript: new_transcript}))
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Discussion: Ask question --

  def apply_ask_question(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    question = fetch(event.payload, :question, "question")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id) do
      transcript = get(state.world, :discussion_transcript, [])

      new_entry = %{
        player: player_id,
        type: "question",
        target: target_id,
        statement: question
      }

      new_transcript = transcript ++ [new_entry]

      # Track pending questions so targets know they should respond
      pending_questions = get(state.world, :pending_questions, [])
      new_pending = pending_questions ++ [%{from: player_id, to: target_id, question: question}]

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            pending_questions: new_pending
          })
        )
        |> State.append_event(event)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Discussion: Accuse --

  def apply_accuse(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    evidence = fetch(event.payload, :evidence, "evidence")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id) do
      transcript = get(state.world, :discussion_transcript, [])

      new_entry = %{
        player: player_id,
        type: "accusation",
        target: target_id,
        statement: evidence
      }

      new_transcript = transcript ++ [new_entry]

      # Track accusations for the UI and agent awareness
      accusations = get(state.world, :accusations, [])

      new_accusations =
        accusations ++ [%{accuser: player_id, accused: target_id, evidence: evidence}]

      target_name = get(Map.get(players, target_id, %{}), :name, target_id)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            accusations: new_accusations
          })
        )
        |> State.append_event(event)
        |> add_journal_entry(
          player_id,
          "Formally accused #{target_name}. I believe they're the saboteur."
        )
        |> adjust_reputation(target_id, -2)

      advance_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Turn advancement --

  defp advance_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)
    discussion_round = get(state.world, :discussion_round, 1)
    discussion_round_limit = get(state.world, :discussion_round_limit, 1)
    round = get(state.world, :round, 1)
    players = get(state.world, :players, %{})

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        if discussion_round < discussion_round_limit do
          next_round = discussion_round + 1
          next_turn_order = Roles.discussion_turn_order(players, round, next_round)
          first_speaker = List.first(next_turn_order)

          next_state =
            State.put_world(
              state,
              world_updates(state.world, %{
                discussion_round: next_round,
                turn_order: next_turn_order,
                active_actor_id: first_speaker
              })
            )

          {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
        else
          Voting.transition_to_voting(state)
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
