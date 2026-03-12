defmodule LemonSim.Examples.SpaceStationUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.SpaceStation
  alias LemonSim.Examples.SpaceStation.{Events, Roles, Updater}
  alias LemonSim.State

  test "discussion uses a second pass before voting when enough players are alive" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    first_order = Roles.discussion_turn_order(players, 1, 1)

    state =
      state
      |> State.put_world(%{
        state.world
        | phase: "discussion",
          round: 1,
          discussion_round: 1,
          discussion_round_limit: 2,
          discussion_transcript: [],
          turn_order: first_order,
          active_actor_id: List.first(first_order)
      })

    {:ok, after_first_pass, {:decide, _}} =
      Enum.reduce(first_order, {:ok, state, nil}, fn actor_id, {:ok, acc_state, _} ->
        Updater.apply_event(
          acc_state,
          Events.make_statement(actor_id, "Signal from #{actor_id}"),
          []
        )
      end)

    assert after_first_pass.world.phase == "discussion"
    assert after_first_pass.world.discussion_round == 2

    second_order = after_first_pass.world.turn_order

    {:ok, after_second_pass, {:decide, _}} =
      Enum.reduce(second_order, {:ok, after_first_pass, nil}, fn actor_id, {:ok, acc_state, _} ->
        Updater.apply_event(
          acc_state,
          Events.make_statement(actor_id, "Follow-up from #{actor_id}"),
          []
        )
      end)

    assert after_second_pass.world.phase == "voting"
    assert after_second_pass.world.discussion_round == 0

    assert after_second_pass.world.active_actor_id ==
             List.first(after_second_pass.world.turn_order)
  end

  test "ejecting the saboteur ends the game with a crew win" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    saboteur_id = Roles.find_saboteur(players)
    voting_order = Roles.voting_turn_order(players, 1)
    crew_voters = Enum.reject(voting_order, &(&1 == saboteur_id))

    state =
      state
      |> State.put_world(%{
        state.world
        | phase: "voting",
          round: 1,
          votes: %{},
          turn_order: voting_order,
          active_actor_id: List.first(voting_order)
      })

    vote_targets =
      Enum.map(voting_order, fn voter_id ->
        {voter_id, if(voter_id in crew_voters, do: saboteur_id, else: "skip")}
      end)

    {:ok, final_state, :skip} =
      Enum.reduce(vote_targets, {:ok, state, nil}, fn {voter_id, target_id},
                                                      {:ok, acc_state, _} ->
        Updater.apply_event(acc_state, Events.cast_vote(voter_id, target_id), [])
      end)

    assert final_state.world.status == "game_over"
    assert final_state.world.winner == "crew"
    assert final_state.world.phase == "game_over"
    assert final_state.world.players[saboteur_id].status == "ejected"
  end
end
