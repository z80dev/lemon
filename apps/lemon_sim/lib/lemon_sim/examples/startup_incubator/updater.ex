defmodule LemonSim.Examples.StartupIncubator.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.StartupIncubator.{Events, Market}

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "make_pitch" -> apply_make_pitch(state, event)
      "ask_question" -> apply_ask_question(state, event)
      "answer_question" -> apply_answer_question(state, event)
      "make_offer" -> apply_make_offer(state, event)
      "counter_offer" -> apply_counter_offer(state, event)
      "accept_deal" -> apply_accept_deal(state, event)
      "reject_deal" -> apply_reject_deal(state, event)
      "merge_startups" -> apply_merge_startups(state, event)
      "allocate_funds" -> apply_allocate_funds(state, event)
      "end_phase" -> apply_end_phase(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # ---------------------------------------------------------------------------
  # Pitch Phase
  # ---------------------------------------------------------------------------

  defp apply_make_pitch(%State{} = state, event) do
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    pitch_text = fetch(event.payload, :pitch_text, "pitch_text", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "pitch"),
         :ok <- ensure_active_actor(state.world, founder_id),
         :ok <- ensure_founder(state.world, founder_id) do
      round = get(state.world, :round, 1)
      pitch_log = get(state.world, :pitch_log, [])

      entry = %{
        "round" => round,
        "founder_id" => founder_id,
        "pitch_text" => pitch_text
      }

      next_world = Map.put(state.world, :pitch_log, pitch_log ++ [entry])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.pitch_delivered(founder_id, pitch_text))

      {next_world2, signal} = advance_phase_actor(next_world, founder_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_id, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Due Diligence Phase
  # ---------------------------------------------------------------------------

  defp apply_ask_question(%State{} = state, event) do
    investor_id = fetch(event.payload, :investor_id, "investor_id")
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    question = fetch(event.payload, :question, "question", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "due_diligence"),
         :ok <- ensure_active_actor(state.world, investor_id),
         :ok <- ensure_investor(state.world, investor_id),
         :ok <- ensure_founder(state.world, founder_id) do
      question_log = get(state.world, :question_log, [])
      round = get(state.world, :round, 1)

      entry = %{
        "round" => round,
        "investor_id" => investor_id,
        "founder_id" => founder_id,
        "question" => question
      }

      # Store in the target founder's pending answers
      pending = get(state.world, :pending_answers, %{})
      founder_pending = Map.get(pending, founder_id, [])
      updated_pending = Map.put(pending, founder_id, founder_pending ++ [entry])

      next_world =
        state.world
        |> Map.put(:question_log, question_log ++ [entry])
        |> Map.put(:pending_answers, updated_pending)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.question_asked(investor_id, founder_id))

      {next_world2, signal} = advance_phase_actor(next_world, investor_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, investor_id, reason)
    end
  end

  defp apply_answer_question(%State{} = state, event) do
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    investor_id = fetch(event.payload, :investor_id, "investor_id")
    answer = fetch(event.payload, :answer, "answer", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "due_diligence"),
         :ok <- ensure_active_actor(state.world, founder_id),
         :ok <- ensure_founder(state.world, founder_id) do
      question_log = get(state.world, :question_log, [])
      round = get(state.world, :round, 1)

      entry = %{
        "round" => round,
        "founder_id" => founder_id,
        "investor_id" => investor_id,
        "answer" => answer
      }

      next_world = Map.put(state.world, :question_log, question_log ++ [entry])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.answer_delivered(founder_id, investor_id))

      {next_world2, signal} = advance_phase_actor(next_world, founder_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_id, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Negotiation Phase
  # ---------------------------------------------------------------------------

  defp apply_make_offer(%State{} = state, event) do
    investor_id = fetch(event.payload, :investor_id, "investor_id")
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    amount = fetch(event.payload, :amount, "amount", 0)
    equity_pct = fetch(event.payload, :equity_pct, "equity_pct", 0.0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "negotiation"),
         :ok <- ensure_active_actor(state.world, investor_id),
         :ok <- ensure_investor(state.world, investor_id),
         :ok <- ensure_founder(state.world, founder_id),
         :ok <- ensure_sufficient_capital(state.world, investor_id, amount) do
      term_sheets = get(state.world, :term_sheets, %{})

      # Key is {investor_id, founder_id}
      sheet_key = "#{investor_id}->#{founder_id}"

      sheet = %{
        "investor_id" => investor_id,
        "founder_id" => founder_id,
        "amount" => amount,
        "equity_pct" => equity_pct,
        "status" => "pending"
      }

      next_world = Map.put(state.world, :term_sheets, Map.put(term_sheets, sheet_key, sheet))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.offer_made(investor_id, founder_id, amount, equity_pct))

      {next_world2, signal} = advance_phase_actor(next_world, investor_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, investor_id, reason)
    end
  end

  defp apply_counter_offer(%State{} = state, event) do
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    investor_id = fetch(event.payload, :investor_id, "investor_id")
    amount = fetch(event.payload, :amount, "amount", 0)
    equity_pct = fetch(event.payload, :equity_pct, "equity_pct", 0.0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "negotiation"),
         :ok <- ensure_active_actor(state.world, founder_id),
         :ok <- ensure_founder(state.world, founder_id),
         :ok <- ensure_existing_offer(state.world, investor_id, founder_id) do
      term_sheets = get(state.world, :term_sheets, %{})
      sheet_key = "#{investor_id}->#{founder_id}"

      updated_sheet =
        term_sheets
        |> Map.get(sheet_key, %{})
        |> Map.merge(%{
          "amount" => amount,
          "equity_pct" => equity_pct,
          "status" => "countered"
        })

      next_world =
        Map.put(state.world, :term_sheets, Map.put(term_sheets, sheet_key, updated_sheet))

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {next_world2, signal} = advance_phase_actor(next_world, founder_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_id, reason)
    end
  end

  defp apply_accept_deal(%State{} = state, event) do
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    investor_id = fetch(event.payload, :investor_id, "investor_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "negotiation"),
         :ok <- ensure_active_actor(state.world, founder_id),
         :ok <- ensure_founder(state.world, founder_id),
         :ok <- ensure_existing_offer(state.world, investor_id, founder_id) do
      term_sheets = get(state.world, :term_sheets, %{})
      sheet_key = "#{investor_id}->#{founder_id}"
      sheet = Map.get(term_sheets, sheet_key, %{})
      amount = Map.get(sheet, "amount", 0)
      equity_pct = Map.get(sheet, "equity_pct", 0.0)

      # Close the deal: update startup funding, deduct investor capital, record
      next_world =
        state.world
        |> close_deal(founder_id, investor_id, amount, equity_pct)
        |> Map.put(
          :term_sheets,
          Map.put(term_sheets, sheet_key, Map.put(sheet, "status", "closed"))
        )

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.deal_closed(founder_id, investor_id, amount, equity_pct))

      {next_world2, signal} = advance_phase_actor(next_world, founder_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_id, reason)
    end
  end

  defp apply_reject_deal(%State{} = state, event) do
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    investor_id = fetch(event.payload, :investor_id, "investor_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "negotiation"),
         :ok <- ensure_active_actor(state.world, founder_id),
         :ok <- ensure_founder(state.world, founder_id) do
      term_sheets = get(state.world, :term_sheets, %{})
      sheet_key = "#{investor_id}->#{founder_id}"

      updated_sheets =
        Map.update(term_sheets, sheet_key, %{}, &Map.put(&1, "status", "rejected"))

      next_world = Map.put(state.world, :term_sheets, updated_sheets)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.deal_rejected(founder_id, investor_id))

      {next_world2, signal} = advance_phase_actor(next_world, founder_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_id, reason)
    end
  end

  defp apply_merge_startups(%State{} = state, event) do
    founder_a_id = fetch(event.payload, :founder_a_id, "founder_a_id")
    founder_b_id = fetch(event.payload, :founder_b_id, "founder_b_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "negotiation"),
         :ok <- ensure_active_actor(state.world, founder_a_id),
         :ok <- ensure_founder(state.world, founder_a_id),
         :ok <- ensure_founder(state.world, founder_b_id),
         :ok <- ensure_not_self(founder_a_id, founder_b_id),
         :ok <- ensure_not_merged(state.world, founder_b_id) do
      next_world = execute_merge(state.world, founder_a_id, founder_b_id)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.startups_merged(founder_a_id, founder_b_id))

      {next_world2, signal} = advance_phase_actor(next_world, founder_a_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_a_id, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Operations Phase
  # ---------------------------------------------------------------------------

  defp apply_allocate_funds(%State{} = state, event) do
    founder_id = fetch(event.payload, :founder_id, "founder_id")
    allocation_type = fetch(event.payload, :allocation_type, "allocation_type", "reserve")
    amount = fetch(event.payload, :amount, "amount", 0)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "operations"),
         :ok <- ensure_active_actor(state.world, founder_id),
         :ok <- ensure_founder(state.world, founder_id),
         :ok <- ensure_valid_allocation_type(allocation_type),
         :ok <- ensure_startup_funds(state.world, founder_id, amount) do
      next_world = execute_allocation(state.world, founder_id, allocation_type, amount)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.funds_allocated(founder_id, allocation_type, amount))

      {next_world2, signal} = advance_phase_actor(next_world, founder_id)
      next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

      {:ok, next_state2, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, founder_id, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # End Phase (explicit "I'm done" signal for pitch/due_diligence/negotiation)
  # ---------------------------------------------------------------------------

  defp apply_end_phase(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    _phase = fetch(event.payload, :phase, "phase", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, player_id) do
      {next_world, signal} = advance_phase_actor(state.world, player_id)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)

      {:ok, next_state, {:decide, signal}}
    else
      {:error, reason} -> reject_action(state, event, player_id, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase/Actor Advancement
  # ---------------------------------------------------------------------------

  # Marks the current actor as done in the current phase, then either advances
  # to the next actor in the same phase or transitions to the next phase/round.
  defp advance_phase_actor(world, current_actor_id) do
    phase = get(world, :phase, "pitch")
    phase_done = get(world, :phase_done, MapSet.new())
    phase_done = MapSet.put(phase_done, current_actor_id)

    world = Map.put(world, :phase_done, phase_done)
    turn_order = get(world, :turn_order, [])
    active_in_phase = active_actors_for_phase(world, phase)

    remaining =
      Enum.reject(active_in_phase, &MapSet.member?(phase_done, &1))

    case remaining do
      [next | _] ->
        next_world = Map.put(world, :active_actor_id, next)
        {next_world, "#{current_actor_id} done with #{phase}, now #{next}'s turn"}

      [] ->
        # Everyone done — run any automatic phase logic then advance
        transition_phase(world, phase, turn_order)
    end
  end

  # Returns the list of player_ids who act during a given phase
  defp active_actors_for_phase(world, phase) do
    players = get(world, :players, %{})
    founders = player_ids_with_role(players, "founder")
    investors = player_ids_with_role(players, "investor")
    all_active = founders ++ investors
    turn_order = get(world, :turn_order, all_active)

    # Retain turn_order ordering but filter to eligible actors
    eligible =
      case phase do
        "pitch" -> founders
        "due_diligence" -> investors ++ founders
        "negotiation" -> investors ++ founders
        "market_event" -> []
        "operations" -> founders
        _ -> all_active
      end

    Enum.filter(turn_order, &(&1 in eligible))
  end

  defp transition_phase(world, current_phase, turn_order) do
    next_phase = next_phase_after(current_phase)

    cond do
      next_phase == "market_event" ->
        # Auto-resolve market event and jump to operations
        {world_after_market, market_events} = run_market_event(world)

        # Rebuild events list for logging — just stored internally
        _ = market_events

        operations_actors = active_actors_for_phase(world_after_market, "operations")
        first_ops = List.first(operations_actors) || List.first(turn_order)

        next_world =
          world_after_market
          |> Map.put(:phase, "operations")
          |> Map.put(:phase_done, MapSet.new())
          |> Map.put(:active_actor_id, first_ops)

        {next_world, "market event resolved, now operations phase for #{first_ops}"}

      next_phase == nil ->
        # End of round; advance or end game
        advance_round(world)

      true ->
        actors = active_actors_for_phase(world, next_phase)
        first = List.first(actors) || List.first(turn_order)

        next_world =
          world
          |> Map.put(:phase, next_phase)
          |> Map.put(:phase_done, MapSet.new())
          |> Map.put(:active_actor_id, first)

        {next_world, "all done with #{current_phase}, now #{next_phase} phase for #{first}"}
    end
  end

  defp next_phase_after("pitch"), do: "due_diligence"
  defp next_phase_after("due_diligence"), do: "negotiation"
  defp next_phase_after("negotiation"), do: "market_event"
  defp next_phase_after("market_event"), do: "operations"
  defp next_phase_after("operations"), do: nil
  defp next_phase_after(_), do: nil

  defp run_market_event(world) do
    market_conditions = get(world, :market_conditions, Market.initial_conditions())
    {new_conditions, event_map} = Market.apply_random_event(market_conditions)

    market_event_log = get(world, :market_event_log, [])
    round = get(world, :round, 1)

    log_entry = %{
      "round" => round,
      "name" => event_map.name,
      "description" => event_map.description,
      "changes" => event_map.changes
    }

    next_world =
      world
      |> Map.put(:market_conditions, new_conditions)
      |> Map.put(:market_event_log, market_event_log ++ [log_entry])

    {next_world, [Events.market_event_applied(event_map.name, event_map.changes)]}
  end

  defp advance_round(world) do
    round = get(world, :round, 1)
    max_rounds = get(world, :max_rounds, 5)

    # Recompute all valuations after operations
    world = recompute_all_valuations(world)

    next_round = round + 1

    if next_round > max_rounds do
      # Game over — determine winner
      {final_world, _events} = determine_winner(world)

      {final_world,
       "game over after #{round} rounds, winner: #{inspect(get(final_world, :winner))}"}
    else
      turn_order = get(world, :turn_order, [])
      pitch_actors = active_actors_for_phase(world, "pitch")
      first = List.first(pitch_actors) || List.first(turn_order)

      next_world =
        world
        |> Map.put(:round, next_round)
        |> Map.put(:phase, "pitch")
        |> Map.put(:phase_done, MapSet.new())
        |> Map.put(:active_actor_id, first)
        |> Map.put(:term_sheets, %{})
        |> Map.put(:pending_answers, %{})

      {next_world, "round #{next_round} begins — pitch phase for #{first}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Deal helpers
  # ---------------------------------------------------------------------------

  defp close_deal(world, founder_id, investor_id, amount, equity_pct) do
    startups = get(world, :startups, %{})
    investors = get(world, :investors, %{})
    deal_history = get(world, :deal_history, [])
    round = get(world, :round, 1)

    startup = Map.get(startups, founder_id, %{})
    investor = Map.get(investors, investor_id, %{})

    # Update startup funding
    current_funding = Map.get(startup, :funding_raised, Map.get(startup, "funding_raised", 0))

    updated_startup =
      startup
      |> Map.put(:funding_raised, current_funding + amount)
      |> Map.put(
        :cash_on_hand,
        Map.get(startup, :cash_on_hand, Map.get(startup, "cash_on_hand", 0)) + amount
      )

    # Update investor capital and portfolio
    remaining = Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0))
    portfolio = Map.get(investor, :portfolio, Map.get(investor, "portfolio", []))

    portfolio_entry = %{
      "founder_id" => founder_id,
      "amount" => amount,
      "equity_pct" => equity_pct,
      "round" => round
    }

    updated_investor =
      investor
      |> Map.put(:remaining_capital, max(0, remaining - amount))
      |> Map.put(:portfolio, portfolio ++ [portfolio_entry])

    deal_entry = %{
      "round" => round,
      "founder_id" => founder_id,
      "investor_id" => investor_id,
      "amount" => amount,
      "equity_pct" => equity_pct
    }

    world
    |> Map.put(:startups, Map.put(startups, founder_id, updated_startup))
    |> Map.put(:investors, Map.put(investors, investor_id, updated_investor))
    |> Map.put(:deal_history, deal_history ++ [deal_entry])
  end

  # ---------------------------------------------------------------------------
  # Merge helpers
  # ---------------------------------------------------------------------------

  defp execute_merge(world, founder_a_id, founder_b_id) do
    startups = get(world, :startups, %{})

    startup_a = Map.get(startups, founder_a_id, %{})
    startup_b = Map.get(startups, founder_b_id, %{})

    # Merge B into A: sum financials, keep A's sector, mark B as merged
    merged_startup =
      startup_a
      |> Map.put(:traction, Map.get(startup_a, :traction, 1) + Map.get(startup_b, :traction, 1))
      |> Map.put(
        :employees,
        Map.get(startup_a, :employees, 1) + Map.get(startup_b, :employees, 1)
      )
      |> Map.put(
        :funding_raised,
        Map.get(startup_a, :funding_raised, 0) + Map.get(startup_b, :funding_raised, 0)
      )
      |> Map.put(
        :cash_on_hand,
        Map.get(startup_a, :cash_on_hand, 0) + Map.get(startup_b, :cash_on_hand, 0)
      )

    merged_b = Map.put(startup_b, :merged_into, founder_a_id)

    world
    |> Map.put(
      :startups,
      startups |> Map.put(founder_a_id, merged_startup) |> Map.put(founder_b_id, merged_b)
    )
  end

  # ---------------------------------------------------------------------------
  # Operations / allocation helpers
  # ---------------------------------------------------------------------------

  defp execute_allocation(world, founder_id, allocation_type, amount) do
    startups = get(world, :startups, %{})
    startup = Map.get(startups, founder_id, %{})

    cash = Map.get(startup, :cash_on_hand, Map.get(startup, "cash_on_hand", 0))
    updated_startup = apply_allocation(startup, allocation_type, amount, cash)

    Map.put(world, :startups, Map.put(startups, founder_id, updated_startup))
  end

  defp apply_allocation(startup, "growth", amount, cash) do
    # Spending on growth boosts traction
    traction_gain = div(amount, 100_000)

    startup
    |> Map.put(:cash_on_hand, max(0, cash - amount))
    |> Map.update(:traction, 1, &(&1 + max(1, traction_gain)))
  end

  defp apply_allocation(startup, "hiring", amount, cash) do
    # Spending on hiring increases employees
    new_employees = div(amount, 80_000)

    startup
    |> Map.put(:cash_on_hand, max(0, cash - amount))
    |> Map.update(:employees, 1, &(&1 + max(1, new_employees)))
  end

  defp apply_allocation(startup, "pivot", amount, cash) do
    # Pivoting costs money, moves to a new sector, resets traction somewhat
    new_sector = Market.random_sector()

    startup
    |> Map.put(:cash_on_hand, max(0, cash - amount))
    |> Map.put(:sector, new_sector)
    |> Map.put(:pivoted?, true)
    |> Map.update(:traction, 1, fn t -> max(1, div(t, 2)) end)
  end

  defp apply_allocation(startup, "reserve", _amount, cash) do
    # Reserve = hold cash, no immediate effect
    startup
    |> Map.put(:cash_on_hand, cash)
  end

  defp apply_allocation(startup, _other, _amount, _cash), do: startup

  # ---------------------------------------------------------------------------
  # Valuation recompute
  # ---------------------------------------------------------------------------

  defp recompute_all_valuations(world) do
    startups = get(world, :startups, %{})
    market_conditions = get(world, :market_conditions, Market.initial_conditions())
    burn_rate_base = 50_000

    updated_startups =
      Enum.into(startups, %{}, fn {founder_id, startup} ->
        unless Map.get(startup, :merged_into) do
          new_valuation = Market.compute_valuation(startup, market_conditions)
          employees = Map.get(startup, :employees, 1)
          burn = employees * burn_rate_base

          # Deduct burn from cash
          cash = max(0, Map.get(startup, :cash_on_hand, 0) - burn)

          updated =
            startup
            |> Map.put(:valuation, new_valuation)
            |> Map.put(:cash_on_hand, cash)
            |> Map.put(:burn_rate, burn)

          {founder_id, updated}
        else
          {founder_id, startup}
        end
      end)

    Map.put(world, :startups, updated_startups)
  end

  # ---------------------------------------------------------------------------
  # Victory determination
  # ---------------------------------------------------------------------------

  defp determine_winner(world) do
    startups = get(world, :startups, %{})
    investors = get(world, :investors, %{})
    market_conditions = get(world, :market_conditions, Market.initial_conditions())

    # Score founders by valuation
    founder_scores =
      Enum.flat_map(startups, fn {founder_id, startup} ->
        if Map.get(startup, :merged_into) do
          []
        else
          val = Market.compute_valuation(startup, market_conditions)
          [{founder_id, val}]
        end
      end)

    # Score investors by portfolio return
    investor_scores =
      Enum.map(investors, fn {investor_id, investor} ->
        portfolio = Map.get(investor, :portfolio, Map.get(investor, "portfolio", []))
        fund_size = Map.get(investor, :fund_size, Map.get(investor, "fund_size", 1))

        remaining =
          Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0))

        deployed = fund_size - remaining

        total_portfolio_value =
          Enum.reduce(portfolio, 0, fn entry, acc ->
            entry_founder = Map.get(entry, "founder_id")
            equity = Map.get(entry, "equity_pct", 0.0)

            startup = Map.get(startups, entry_founder, %{})
            valuation = Market.compute_valuation(startup, market_conditions)
            stake_value = round(valuation * equity / 100.0)
            acc + stake_value
          end)

        return =
          if deployed > 0, do: (total_portfolio_value - deployed) / deployed * 100.0, else: 0.0

        {investor_id, round(return)}
      end)

    all_scores = founder_scores ++ investor_scores

    {winner, _score} =
      Enum.max_by(all_scores, fn {_id, score} -> score end, fn -> {nil, 0} end)

    final_world =
      world
      |> Map.put(:status, "won")
      |> Map.put(:winner, winner)
      |> Map.put(:final_scores, Map.new(all_scores))

    {final_world, [Events.game_over("won", winner || "nobody")]}
  end

  # ---------------------------------------------------------------------------
  # Validation guards
  # ---------------------------------------------------------------------------

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

  defp ensure_founder(world, player_id) do
    players = get(world, :players, %{})

    case Map.get(players, player_id) do
      nil -> {:error, :unknown_player}
      p -> if get(p, :role, "founder") == "founder", do: :ok, else: {:error, :wrong_role}
    end
  end

  defp ensure_investor(world, player_id) do
    players = get(world, :players, %{})

    case Map.get(players, player_id) do
      nil -> {:error, :unknown_player}
      p -> if get(p, :role, "investor") == "investor", do: :ok, else: {:error, :wrong_role}
    end
  end

  defp ensure_not_self(a, b) do
    if a != b, do: :ok, else: {:error, :cannot_target_self}
  end

  defp ensure_not_merged(world, founder_id) do
    startups = get(world, :startups, %{})
    startup = Map.get(startups, founder_id, %{})

    if Map.get(startup, :merged_into),
      do: {:error, :already_merged},
      else: :ok
  end

  defp ensure_sufficient_capital(world, investor_id, amount) do
    investors = get(world, :investors, %{})
    investor = Map.get(investors, investor_id, %{})
    remaining = Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0))

    if remaining >= amount, do: :ok, else: {:error, :insufficient_funds}
  end

  defp ensure_startup_funds(world, founder_id, amount) do
    startups = get(world, :startups, %{})
    startup = Map.get(startups, founder_id, %{})
    cash = Map.get(startup, :cash_on_hand, Map.get(startup, "cash_on_hand", 0))

    if cash >= amount, do: :ok, else: {:error, :insufficient_funds}
  end

  defp ensure_existing_offer(world, investor_id, founder_id) do
    term_sheets = get(world, :term_sheets, %{})
    sheet_key = "#{investor_id}->#{founder_id}"

    case Map.get(term_sheets, sheet_key) do
      nil ->
        {:error, :no_offer}

      sheet ->
        if Map.get(sheet, "status") in ["pending", "countered"],
          do: :ok,
          else: {:error, :no_active_offer}
    end
  end

  defp ensure_valid_allocation_type(type) when type in ~w(growth hiring pivot reserve), do: :ok
  defp ensure_valid_allocation_type(_), do: {:error, :invalid_allocation_type}

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

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
  defp rejection_reason(:unknown_player), do: "unknown player id"
  defp rejection_reason(:wrong_role), do: "wrong role for this action"
  defp rejection_reason(:cannot_target_self), do: "cannot target yourself"
  defp rejection_reason(:insufficient_funds), do: "insufficient funds"
  defp rejection_reason(:no_offer), do: "no offer exists from that investor"
  defp rejection_reason(:no_active_offer), do: "no active offer to respond to"
  defp rejection_reason(:already_merged), do: "that startup has already been merged"

  defp rejection_reason(:invalid_allocation_type),
    do: "invalid allocation type (use growth/hiring/pivot/reserve)"

  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  defp player_ids_with_role(players, role) do
    players
    |> Enum.filter(fn {_id, p} -> get(p, :role, "founder") == role end)
    |> Enum.map(fn {id, _p} -> id end)
  end
end
