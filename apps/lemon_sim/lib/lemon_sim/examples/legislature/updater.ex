defmodule LemonSim.Examples.Legislature.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.Legislature.{Bills, Events}

  @amendment_cost 20
  @max_caucus_messages 3

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "send_message" -> apply_send_message(state, event)
      "propose_trade" -> apply_propose_trade(state, event)
      "end_caucus" -> apply_end_caucus(state, event)
      "make_speech" -> apply_make_speech(state, event)
      "end_floor_debate" -> apply_end_floor_debate(state, event)
      "propose_amendment" -> apply_propose_amendment(state, event)
      "lobby" -> apply_lobby(state, event)
      "end_amendment" -> apply_end_amendment(state, event)
      "cast_amendment_vote" -> apply_cast_amendment_vote(state, event)
      "end_amendment_vote" -> apply_end_amendment_vote(state, event)
      "cast_votes" -> apply_cast_votes(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Caucus: Send Message --

  defp apply_send_message(%State{} = state, event) do
    sender_id = fetch(event.payload, :sender_id, "sender_id")
    recipient_id = fetch(event.payload, :recipient_id, "recipient_id")
    message = fetch(event.payload, :message, "message", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "caucus"),
         :ok <- ensure_active_actor(state.world, sender_id),
         :ok <- ensure_valid_player(state.world, recipient_id),
         :ok <- ensure_not_self(sender_id, recipient_id),
         :ok <- ensure_caucus_message_quota(state.world, sender_id) do
      session = get(state.world, :session, 1)

      inbox = get(state.world, :caucus_messages, %{})
      recipient_inbox = Map.get(inbox, recipient_id, [])

      new_msg = %{
        "from" => sender_id,
        "to" => recipient_id,
        "message" => message,
        "session" => session
      }

      updated_inbox = Map.put(inbox, recipient_id, recipient_inbox ++ [new_msg])

      sent_counts = get(state.world, :caucus_messages_sent, %{})
      player_sent = Map.get(sent_counts, sender_id, %{})
      session_count = Map.get(player_sent, session, 0) + 1
      updated_sent = Map.put(sent_counts, sender_id, Map.put(player_sent, session, session_count))

      message_history = get(state.world, :message_history, [])

      next_world =
        state.world
        |> Map.put(:caucus_messages, updated_inbox)
        |> Map.put(:caucus_messages_sent, updated_sent)
        |> Map.put(
          :message_history,
          message_history ++ [%{session: session, from: sender_id, to: recipient_id}]
        )

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.message_delivered(sender_id, recipient_id, message))

      {:ok, next_state, {:decide, "#{sender_id} sent a message, continue caucus"}}
    else
      {:error, reason} ->
        reject_action(state, event, sender_id, reason)
    end
  end

  # -- Caucus: Propose Trade --

  defp apply_propose_trade(%State{} = state, event) do
    proposer_id = fetch(event.payload, :proposer_id, "proposer_id")
    recipient_id = fetch(event.payload, :recipient_id, "recipient_id")
    bill_a = fetch(event.payload, :bill_a, "bill_a")
    bill_b = fetch(event.payload, :bill_b, "bill_b")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "caucus"),
         :ok <- ensure_active_actor(state.world, proposer_id),
         :ok <- ensure_valid_player(state.world, recipient_id),
         :ok <- ensure_not_self(proposer_id, recipient_id),
         :ok <- ensure_valid_bill(state.world, bill_a),
         :ok <- ensure_valid_bill(state.world, bill_b),
         :ok <- ensure_caucus_message_quota(state.world, proposer_id) do
      session = get(state.world, :session, 1)

      inbox = get(state.world, :caucus_messages, %{})
      recipient_inbox = Map.get(inbox, recipient_id, [])

      new_msg = %{
        "from" => proposer_id,
        "to" => recipient_id,
        "type" => "trade_proposal",
        "bill_a" => bill_a,
        "bill_b" => bill_b,
        "message" =>
          "I propose: I vote YES on #{bill_a} if you vote YES on #{bill_b}.",
        "session" => session
      }

      updated_inbox = Map.put(inbox, recipient_id, recipient_inbox ++ [new_msg])

      sent_counts = get(state.world, :caucus_messages_sent, %{})
      player_sent = Map.get(sent_counts, proposer_id, %{})
      session_count = Map.get(player_sent, session, 0) + 1
      updated_sent = Map.put(sent_counts, proposer_id, Map.put(player_sent, session, session_count))

      message_history = get(state.world, :message_history, [])

      next_world =
        state.world
        |> Map.put(:caucus_messages, updated_inbox)
        |> Map.put(:caucus_messages_sent, updated_sent)
        |> Map.put(
          :message_history,
          message_history ++ [%{session: session, from: proposer_id, to: recipient_id, type: "trade"}]
        )

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.trade_proposed(proposer_id, recipient_id, bill_a, bill_b))

      {:ok, next_state, {:decide, "#{proposer_id} proposed a trade, continue caucus"}}
    else
      {:error, reason} ->
        reject_action(state, event, proposer_id, reason)
    end
  end

  # -- Caucus: End Caucus --

  defp apply_end_caucus(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "caucus"),
         :ok <- ensure_active_actor(state.world, player_id) do
      caucus_done = get(state.world, :caucus_done, MapSet.new())
      caucus_done = MapSet.put(caucus_done, player_id)

      next_world = Map.put(state.world, :caucus_done, caucus_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.caucus_ended(player_id))

      all_players = player_ids(next_world)
      all_done = Enum.all?(all_players, &MapSet.member?(caucus_done, &1))

      if all_done do
        next_world2 =
          next_world
          |> Map.put(:phase, "floor_debate")
          |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
          |> Map.put(:floor_debate_done, MapSet.new())

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("caucus", "floor_debate"))

        {:ok, next_state2,
         {:decide,
          "all players finished caucus, now in floor_debate phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, caucus_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished caucus, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Floor Debate: Make Speech --

  defp apply_make_speech(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    bill_id = fetch(event.payload, :bill_id, "bill_id")
    speech = fetch(event.payload, :speech, "speech", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "floor_debate"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_bill(state.world, bill_id) do
      session = get(state.world, :session, 1)

      floor_statements = get(state.world, :floor_statements, [])

      new_statement = %{
        "player_id" => player_id,
        "bill_id" => bill_id,
        "speech" => speech,
        "session" => session
      }

      next_world =
        state.world
        |> Map.put(:floor_statements, floor_statements ++ [new_statement])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.speech_delivered(player_id, bill_id))

      {:ok, next_state, {:decide, "#{player_id} made a speech about #{bill_id}, end floor debate when done"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Floor Debate: End Floor Debate --

  defp apply_end_floor_debate(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "floor_debate"),
         :ok <- ensure_active_actor(state.world, player_id) do
      floor_debate_done = get(state.world, :floor_debate_done, MapSet.new())
      floor_debate_done = MapSet.put(floor_debate_done, player_id)

      next_world = Map.put(state.world, :floor_debate_done, floor_debate_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.floor_debate_ended(player_id))

      all_players = player_ids(next_world)
      all_done = Enum.all?(all_players, &MapSet.member?(floor_debate_done, &1))

      if all_done do
        next_world2 =
          next_world
          |> Map.put(:phase, "amendment")
          |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
          |> Map.put(:amendment_done, MapSet.new())

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("floor_debate", "amendment"))

        {:ok, next_state2,
         {:decide,
          "all players finished floor debate, now in amendment phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, floor_debate_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished floor debate, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Amendment: Propose Amendment --

  defp apply_propose_amendment(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    bill_id = fetch(event.payload, :bill_id, "bill_id")
    amendment_text = fetch(event.payload, :amendment_text, "amendment_text", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "amendment"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_bill(state.world, bill_id),
         :ok <- ensure_sufficient_capital(state.world, player_id, @amendment_cost) do
      session = get(state.world, :session, 1)
      amendment_id = "amendment_#{session}_#{player_id}_#{bill_id}"

      proposed_amendments = get(state.world, :proposed_amendments, [])

      new_amendment = %{
        id: amendment_id,
        proposer_id: player_id,
        bill_id: bill_id,
        amendment_text: amendment_text,
        session: session,
        votes: %{},
        passed: nil
      }

      # Deduct political capital
      players = get(state.world, :players, %{})
      player_data = Map.get(players, player_id, %{})
      current_capital = Map.get(player_data, :political_capital, 100)
      updated_player = Map.put(player_data, :political_capital, current_capital - @amendment_cost)
      updated_players = Map.put(players, player_id, updated_player)

      next_world =
        state.world
        |> Map.put(:proposed_amendments, proposed_amendments ++ [new_amendment])
        |> Map.put(:players, updated_players)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(
          Events.amendment_proposed(player_id, bill_id, amendment_id, amendment_text)
        )

      {:ok, next_state,
       {:decide,
        "#{player_id} proposed amendment #{amendment_id} to #{bill_id}, can lobby or end amendment"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Amendment: Lobby --

  defp apply_lobby(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    bill_id = fetch(event.payload, :bill_id, "bill_id")
    capital_spent = fetch(event.payload, :capital_spent, "capital_spent", 0)
    capital_spent = if is_integer(capital_spent), do: capital_spent, else: 0

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "amendment"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_bill(state.world, bill_id),
         :ok <- ensure_sufficient_capital(state.world, player_id, capital_spent),
         :ok <- ensure_positive_amount(capital_spent) do
      bills = get(state.world, :bills, %{})
      bill = Map.get(bills, bill_id, %{})
      lobby_support = Map.get(bill, :lobby_support, Map.get(bill, "lobby_support", %{}))
      current_support = Map.get(lobby_support, player_id, 0)
      updated_lobby = Map.put(lobby_support, player_id, current_support + capital_spent)
      updated_bill = Map.put(bill, :lobby_support, updated_lobby)
      updated_bills = Map.put(bills, bill_id, updated_bill)

      players = get(state.world, :players, %{})
      player_data = Map.get(players, player_id, %{})
      current_capital = Map.get(player_data, :political_capital, 100)
      updated_player = Map.put(player_data, :political_capital, current_capital - capital_spent)
      updated_players = Map.put(players, player_id, updated_player)

      next_world =
        state.world
        |> Map.put(:bills, updated_bills)
        |> Map.put(:players, updated_players)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.lobby_recorded(player_id, bill_id, capital_spent))

      {:ok, next_state,
       {:decide, "#{player_id} lobbied #{bill_id} with #{capital_spent} capital"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Amendment: End Amendment --

  defp apply_end_amendment(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "amendment"),
         :ok <- ensure_active_actor(state.world, player_id) do
      amendment_done = get(state.world, :amendment_done, MapSet.new())
      amendment_done = MapSet.put(amendment_done, player_id)

      next_world = Map.put(state.world, :amendment_done, amendment_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.amendment_ended(player_id))

      all_players = player_ids(next_world)
      all_done = Enum.all?(all_players, &MapSet.member?(amendment_done, &1))

      if all_done do
        pending = get(next_world, :proposed_amendments, [])

        if pending == [] do
          # No amendments to vote on, skip to final vote
          next_world2 =
            next_world
            |> Map.put(:phase, "final_vote")
            |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
            |> Map.put(:votes_cast, MapSet.new())

          next_state2 =
            next_state
            |> State.update_world(fn _ -> next_world2 end)
            |> State.append_event(Events.phase_changed("amendment", "final_vote"))

          {:ok, next_state2,
           {:decide,
            "no amendments proposed, skipping to final_vote for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
        else
          next_world2 =
            next_world
            |> Map.put(:phase, "amendment_vote")
            |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
            |> Map.put(:amendment_vote_done, MapSet.new())

          next_state2 =
            next_state
            |> State.update_world(fn _ -> next_world2 end)
            |> State.append_event(Events.phase_changed("amendment", "amendment_vote"))

          {:ok, next_state2,
           {:decide,
            "all players finished amendments, now in amendment_vote phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
        end
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, amendment_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished amendment phase, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Amendment Vote: Cast Amendment Vote --

  defp apply_cast_amendment_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    amendment_id = fetch(event.payload, :amendment_id, "amendment_id")
    vote = fetch(event.payload, :vote, "vote", "yes")
    bill_id = fetch(event.payload, :bill_id, "bill_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "amendment_vote"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_valid_vote(vote) do
      proposed = get(state.world, :proposed_amendments, [])

      amendment_idx = Enum.find_index(proposed, fn a ->
        Map.get(a, :id, Map.get(a, "id")) == amendment_id
      end)

      if amendment_idx == nil do
        reject_action(state, event, player_id, :invalid_amendment)
      else
        amendment = Enum.at(proposed, amendment_idx)
        votes = Map.get(amendment, :votes, %{})
        updated_votes = Map.put(votes, player_id, vote)
        updated_amendment = Map.put(amendment, :votes, updated_votes)
        updated_proposed = List.replace_at(proposed, amendment_idx, updated_amendment)

        next_world = Map.put(state.world, :proposed_amendments, updated_proposed)

        next_state =
          state
          |> State.update_world(fn _ -> next_world end)
          |> State.append_event(event)
          |> State.append_event(Events.amendment_vote_cast(player_id, amendment_id, vote))

        {:ok, next_state,
         {:decide,
          "#{player_id} voted #{vote} on amendment #{amendment_id} for #{bill_id}"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Amendment Vote: End Amendment Vote --

  defp apply_end_amendment_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "amendment_vote"),
         :ok <- ensure_active_actor(state.world, player_id) do
      amendment_vote_done = get(state.world, :amendment_vote_done, MapSet.new())
      amendment_vote_done = MapSet.put(amendment_vote_done, player_id)

      next_world = Map.put(state.world, :amendment_vote_done, amendment_vote_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.amendment_vote_ended(player_id))

      all_players = player_ids(next_world)
      all_done = Enum.all?(all_players, &MapSet.member?(amendment_vote_done, &1))

      if all_done do
        # Resolve all amendment votes
        {resolved_world, resolution_events} = resolve_amendment_votes(next_world)

        next_world2 =
          resolved_world
          |> Map.put(:phase, "final_vote")
          |> Map.put(:active_actor_id, List.first(get(resolved_world, :turn_order, [])))
          |> Map.put(:votes_cast, MapSet.new())

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_events(resolution_events)
          |> State.append_event(Events.phase_changed("amendment_vote", "final_vote"))

        {:ok, next_state2,
         {:decide,
          "amendments resolved, now in final_vote for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        {next_world2, _} = advance_to_next_player(next_world, player_id, amendment_vote_done)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished amendment voting, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Final Vote: Cast Votes --

  defp apply_cast_votes(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    votes = fetch(event.payload, :votes, "votes", %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "final_vote"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_votes_not_cast(state.world, player_id) do
      votes_cast = get(state.world, :votes_cast, MapSet.new())
      votes_cast = MapSet.put(votes_cast, player_id)

      vote_record = get(state.world, :vote_record, %{})
      updated_vote_record = Map.put(vote_record, player_id, votes)

      next_world =
        state.world
        |> Map.put(:votes_cast, votes_cast)
        |> Map.put(:vote_record, updated_vote_record)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.votes_cast(player_id, votes))

      all_players = player_ids(next_world)
      all_voted = Enum.all?(all_players, &MapSet.member?(votes_cast, &1))

      if all_voted do
        # Resolve all votes and score
        {final_world, result_events} = resolve_final_votes(next_world)
        {scored_world, score_events} = apply_scoring(final_world)

        # Check for end of session / game over
        {end_world, end_events} = advance_session_or_end(scored_world)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> end_world end)
          |> State.append_events(result_events)
          |> State.append_events(score_events)
          |> State.append_events(end_events)

        if get(end_world, :status, "in_progress") != "in_progress" do
          {:ok, next_state2, :skip}
        else
          {:ok, next_state2,
           {:decide,
            "voting complete, session #{get(end_world, :session, 1)} caucus phase for #{MapHelpers.get_key(end_world, :active_actor_id)}"}}
        end
      else
        # Advance to next player to vote
        {next_world2, _} = advance_to_next_player(next_world, player_id, votes_cast)
        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} cast votes, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn to vote"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Amendment Vote Resolution --

  defp resolve_amendment_votes(world) do
    proposed = get(world, :proposed_amendments, [])
    player_count = map_size(get(world, :players, %{}))
    majority = div(player_count, 2) + 1

    {resolved_amendments, resolution_events} =
      Enum.map_reduce(proposed, [], fn amendment, events_acc ->
        votes = Map.get(amendment, :votes, %{})
        yes_count = Enum.count(votes, fn {_k, v} -> v == "yes" end)
        passed = yes_count >= majority

        amendment_id = Map.get(amendment, :id, "")
        bill_id = Map.get(amendment, :bill_id, "")

        resolved = Map.put(amendment, :passed, passed)
        event = Events.amendment_resolved(amendment_id, bill_id, passed)
        {resolved, events_acc ++ [event]}
      end)

    # Apply successful amendments to bills
    bills = get(world, :bills, %{})

    updated_bills =
      Enum.reduce(resolved_amendments, bills, fn amendment, bills_acc ->
        if Map.get(amendment, :passed, false) do
          bill_id = Map.get(amendment, :bill_id, "")
          amendment_text = Map.get(amendment, :amendment_text, "")
          amendment_id = Map.get(amendment, :id, "")

          bill = Map.get(bills_acc, bill_id, %{})
          existing_amendments = Map.get(bill, :amendments, Map.get(bill, "amendments", []))
          updated_bill = Map.put(bill, :amendments, existing_amendments ++ [%{id: amendment_id, text: amendment_text}])
          Map.put(bills_acc, bill_id, updated_bill)
        else
          bills_acc
        end
      end)

    resolved_world =
      world
      |> Map.put(:proposed_amendments, resolved_amendments)
      |> Map.put(:bills, updated_bills)

    {resolved_world, resolution_events}
  end

  # -- Final Vote Resolution --

  defp resolve_final_votes(world) do
    bills = get(world, :bills, %{})
    vote_record = get(world, :vote_record, %{})
    player_count = map_size(get(world, :players, %{}))
    majority = div(player_count, 2) + 1

    {bill_events, updated_bills} =
      Enum.map_reduce(Bills.bill_ids(), bills, fn bill_id, bills_acc ->
        bill = Map.get(bills_acc, bill_id, %{})

        yes_count =
          Enum.count(vote_record, fn {_player, votes} ->
            v = Map.get(votes, bill_id, Map.get(votes, :bill_id))
            v == "yes"
          end)

        no_count = player_count - yes_count
        passed = yes_count >= majority

        status = if passed, do: "passed", else: "failed"
        updated_bill = Map.put(bill, :status, status)
        event = Events.bill_voted(bill_id, passed, yes_count, no_count)

        {event, Map.put(bills_acc, bill_id, updated_bill)}
      end)

    next_world = Map.put(world, :bills, updated_bills)
    {next_world, bill_events}
  end

  # -- Scoring --

  defp apply_scoring(world) do
    bills = get(world, :bills, %{})
    players = get(world, :players, %{})
    scores = get(world, :scores, %{})
    resolved_amendments = get(world, :proposed_amendments, [])

    passed_bill_ids =
      bills
      |> Enum.filter(fn {_id, bill} ->
        Map.get(bill, :status, Map.get(bill, "status")) == "passed"
      end)
      |> Enum.map(fn {id, _} -> id end)

    bill_score_delta = Bills.score_passed_bills(players, passed_bill_ids)
    amendment_score_delta = Bills.score_amendments(players, resolved_amendments)
    capital_score_delta = Bills.score_capital(players)

    combined_delta =
      Enum.into(players, %{}, fn {player_id, _} ->
        bill_pts = Map.get(bill_score_delta, player_id, 0)
        amendment_pts = Map.get(amendment_score_delta, player_id, 0)
        capital_pts = Map.get(capital_score_delta, player_id, 0)
        {player_id, bill_pts + amendment_pts + capital_pts}
      end)

    updated_scores =
      Enum.reduce(combined_delta, scores, fn {player_id, delta}, acc ->
        Map.update(acc, player_id, delta, &(&1 + delta))
      end)

    next_world = Map.put(world, :scores, updated_scores)
    {next_world, [Events.scores_updated(combined_delta)]}
  end

  # -- Session Advancement --

  defp advance_session_or_end(world) do
    session = get(world, :session, 1)
    max_sessions = get(world, :max_sessions, 3)

    if session >= max_sessions do
      # Game over: highest score wins
      scores = get(world, :scores, %{})

      {winner, _score} =
        scores
        |> Enum.max_by(fn {_player, score} -> score end, fn -> {nil, 0} end)

      final_world =
        world
        |> Map.put(:status, "won")
        |> Map.put(:winner, winner)

      {final_world, [Events.game_over("won", winner)]}
    else
      new_session = session + 1

      # Reset per-session state
      next_world =
        world
        |> Map.put(:session, new_session)
        |> Map.put(:phase, "caucus")
        |> Map.put(:active_actor_id, List.first(get(world, :turn_order, [])))
        |> Map.put(:caucus_done, MapSet.new())
        |> Map.put(:floor_debate_done, MapSet.new())
        |> Map.put(:amendment_done, MapSet.new())
        |> Map.put(:amendment_vote_done, MapSet.new())
        |> Map.put(:votes_cast, MapSet.new())
        |> Map.put(:proposed_amendments, [])
        |> Map.put(:floor_statements, [])
        |> reset_bills_for_new_session()

      {next_world,
       [Events.phase_changed("scoring", "caucus"), Events.session_advanced(new_session)]}
    end
  end

  defp reset_bills_for_new_session(world) do
    bills = get(world, :bills, %{})

    reset_bills =
      Enum.into(bills, %{}, fn {bill_id, bill} ->
        reset_bill =
          bill
          |> Map.put(:status, "pending")
          |> Map.put(:lobby_support, %{})

        {bill_id, reset_bill}
      end)

    Map.put(world, :bills, reset_bills)
  end

  # -- Phase Helpers --

  defp advance_to_next_player(world, current_player, done_set) do
    turn_order = get(world, :turn_order, [])
    all = player_ids(world)

    remaining =
      turn_order
      |> Enum.filter(&(&1 in all))
      |> Enum.reject(&MapSet.member?(done_set, &1))

    next_player =
      case remaining do
        [] -> current_player
        [first | _] -> first
      end

    next_world = Map.put(world, :active_actor_id, next_player)
    {next_world, []}
  end

  defp player_ids(world) do
    players = get(world, :players, %{})
    Map.keys(players)
  end

  # -- Validation --

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :game_over}
  end

  defp ensure_phase(world, expected_phase) do
    if get(world, :phase, nil) == expected_phase,
      do: :ok,
      else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, player_id) do
    if MapHelpers.get_key(world, :active_actor_id) == player_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp ensure_valid_player(world, player_id) do
    players = get(world, :players, %{})

    if Map.has_key?(players, player_id),
      do: :ok,
      else: {:error, :invalid_player}
  end

  defp ensure_not_self(sender_id, recipient_id) do
    if sender_id != recipient_id,
      do: :ok,
      else: {:error, :cannot_message_self}
  end

  defp ensure_caucus_message_quota(world, player_id) do
    session = get(world, :session, 1)
    sent_counts = get(world, :caucus_messages_sent, %{})
    player_sent = Map.get(sent_counts, player_id, %{})
    count = Map.get(player_sent, session, 0)

    if count < @max_caucus_messages,
      do: :ok,
      else: {:error, :message_quota_exceeded}
  end

  defp ensure_valid_bill(world, bill_id) do
    bills = get(world, :bills, %{})

    if Map.has_key?(bills, bill_id),
      do: :ok,
      else: {:error, :invalid_bill}
  end

  defp ensure_sufficient_capital(world, player_id, amount) do
    players = get(world, :players, %{})
    player_data = Map.get(players, player_id, %{})
    capital = Map.get(player_data, :political_capital, Map.get(player_data, "political_capital", 0))

    if capital >= amount,
      do: :ok,
      else: {:error, :insufficient_capital}
  end

  defp ensure_positive_amount(amount) do
    if amount > 0,
      do: :ok,
      else: {:error, :invalid_amount}
  end

  defp ensure_valid_vote(vote) when vote in ["yes", "no"], do: :ok
  defp ensure_valid_vote(_), do: {:error, :invalid_vote}

  defp ensure_votes_not_cast(world, player_id) do
    votes_cast = get(world, :votes_cast, MapSet.new())

    if MapSet.member?(votes_cast, player_id),
      do: {:error, :already_voted},
      else: :ok
  end

  # -- Error handling --

  defp reject_action(%State{} = state, event, player_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(event.kind, to_string(player_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:wrong_phase), do: "wrong phase for this action"
  defp rejection_reason(:not_active_actor), do: "not the active player"
  defp rejection_reason(:invalid_player), do: "invalid player id"
  defp rejection_reason(:cannot_message_self), do: "cannot send message to yourself"
  defp rejection_reason(:message_quota_exceeded), do: "message quota exceeded (max #{@max_caucus_messages} per session)"
  defp rejection_reason(:invalid_bill), do: "invalid bill id"
  defp rejection_reason(:insufficient_capital), do: "insufficient political capital"
  defp rejection_reason(:invalid_amount), do: "amount must be positive"
  defp rejection_reason(:invalid_vote), do: "invalid vote (use yes/no)"
  defp rejection_reason(:already_voted), do: "you have already cast your votes this session"
  defp rejection_reason(:invalid_amendment), do: "invalid amendment id"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"
end
