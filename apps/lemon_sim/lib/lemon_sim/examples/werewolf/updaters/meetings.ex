defmodule LemonSim.Examples.Werewolf.Updaters.Meetings do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.{Events, Roles, RulesConfig}
  alias LemonSim.Examples.Werewolf.Updaters.{Discussion, VillageEvents}

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_request_meeting(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "meeting_selection"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
      meeting_requests =
        state.world
        |> get(:meeting_requests, %{})
        |> Map.put(player_id, target_id)

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{meeting_requests: meeting_requests}))
        |> State.append_event(event)

      advance_meeting_selection(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_meeting_selection(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        resolve_meeting_pairs(state)

      next_actor ->
        next_state =
          State.put_world(state, world_updates(state.world, %{active_actor_id: next_actor}))

        {:ok, next_state, {:decide, "#{next_actor} meeting selection"}}
    end
  end

  defp resolve_meeting_pairs(%State{} = state) do
    requests = get(state.world, :meeting_requests, %{})
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

    living_ids =
      players |> Roles.living_players() |> Enum.map(fn {id, _} -> id end) |> Enum.sort()

    pairs = build_meeting_pairs(requests, living_ids)

    if pairs == [] do
      transition_to_day_discussion_from_meetings(state)
    else
      [first_pair | _] = pairs
      [first_speaker, second_speaker] = first_pair

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            phase: "private_meeting",
            meeting_pairs: pairs,
            current_meeting_index: 0,
            current_meeting_messages: [],
            turn_order: first_pair,
            active_actor_id: first_speaker
          })
        )
        |> State.append_event(Events.phase_changed("private_meeting", day_number))

      {:ok, next_state, {:decide, "#{first_speaker} meeting with #{second_speaker}"}}
    end
  end

  defp build_meeting_pairs(requests, living_ids) do
    mutual =
      requests
      |> Enum.filter(fn {a, b} -> Map.get(requests, b) == a and a < b end)
      |> Enum.map(fn {a, b} -> [a, b] end)

    mutually_paired = mutual |> List.flatten() |> MapSet.new()

    {directed, paired} =
      requests
      |> Enum.sort_by(fn {requester, target} -> {requester, target} end)
      |> Enum.reduce({[], mutually_paired}, fn {requester, target}, {pairs, paired} ->
        if requester in living_ids and target in living_ids and
             not MapSet.member?(paired, requester) and not MapSet.member?(paired, target) do
          {pairs ++ [[requester, target]], paired |> MapSet.put(requester) |> MapSet.put(target)}
        else
          {pairs, paired}
        end
      end)

    unpaired = Enum.reject(living_ids, &MapSet.member?(paired, &1))
    remaining_pairs = unpaired |> Enum.chunk_every(2, 2, :discard)

    (mutual ++ directed ++ remaining_pairs)
    |> Enum.take(div(length(living_ids), 2))
  end

  def apply_meeting_message(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    message = fetch(event.payload, :message, "message")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "private_meeting"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_text(message) do
      current_messages = get(state.world, :current_meeting_messages, [])
      new_messages = current_messages ++ [%{player: player_id, message: message}]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{current_meeting_messages: new_messages}))
        |> State.append_event(event)

      advance_meeting_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_meeting_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        complete_current_meeting(state)

      next_actor ->
        next_state =
          State.put_world(state, world_updates(state.world, %{active_actor_id: next_actor}))

        {:ok, next_state, {:decide, "#{next_actor} meeting message"}}
    end
  end

  defp complete_current_meeting(%State{} = state) do
    pairs = get(state.world, :meeting_pairs, [])
    current_idx = get(state.world, :current_meeting_index, 0)
    current_messages = get(state.world, :current_meeting_messages, [])
    day_number = get(state.world, :day_number, 1)
    meeting_transcripts = get(state.world, :meeting_transcripts, [])
    current_pair = Enum.at(pairs, current_idx, [])

    new_transcript = %{day: day_number, pair: current_pair, messages: current_messages}
    new_transcripts = meeting_transcripts ++ [new_transcript]
    next_idx = current_idx + 1

    if next_idx < length(pairs) do
      next_pair = Enum.at(pairs, next_idx)
      [first_speaker, second_speaker] = next_pair

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            meeting_transcripts: new_transcripts,
            current_meeting_index: next_idx,
            current_meeting_messages: [],
            turn_order: next_pair,
            active_actor_id: first_speaker
          })
        )

      {:ok, next_state, {:decide, "#{first_speaker} meeting with #{second_speaker}"}}
    else
      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            meeting_transcripts: new_transcripts,
            current_meeting_index: 0,
            current_meeting_messages: []
          })
        )

      transition_to_day_discussion_from_meetings(next_state)
    end
  end

  defp transition_to_day_discussion_from_meetings(%State{} = state) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

    discussion_round_limit =
      players
      |> Roles.discussion_round_limit(day_number)
      |> VillageEvents.adjust_discussion_round_limit(get(state.world, :current_village_event))

    discussion_order = Roles.discussion_turn_order(players, day_number, 1)

    discussion_turn_limit =
      Discussion.discussion_turn_limit(discussion_order, discussion_round_limit)

    first_speaker = List.first(discussion_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "day_discussion",
          discussion_transcript: [],
          discussion_round: 1,
          discussion_round_limit: discussion_round_limit,
          discussion_turn_count: 0,
          discussion_turn_limit: discussion_turn_limit,
          votes: %{},
          turn_order: discussion_order,
          active_actor_id: first_speaker,
          meeting_requests: %{},
          meeting_pairs: []
        })
      )
      |> State.append_event(Events.phase_changed("day_discussion", day_number))

    {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
  end

  def transition_to_meetings_or_discussion(%State{} = state) do
    if RulesConfig.enabled?(state.world, :private_meetings) do
      transition_to_meeting_selection(state)
    else
      transition_to_day_discussion_from_meetings(state)
    end
  end

  def resolve_requested_meetings_or_discussion(%State{} = state) do
    if RulesConfig.enabled?(state.world, :private_meetings) do
      resolve_meeting_pairs(state)
    else
      transition_to_day_discussion_from_meetings(state)
    end
  end

  defp transition_to_meeting_selection(%State{} = state) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

    living_ids =
      players |> Roles.living_players() |> Enum.map(fn {id, _} -> id end) |> Enum.sort()

    first_player = List.first(living_ids)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "meeting_selection",
          meeting_requests: %{},
          meeting_pairs: [],
          current_meeting_messages: [],
          turn_order: living_ids,
          active_actor_id: first_player
        })
      )
      |> State.append_event(Events.phase_changed("meeting_selection", day_number))

    {:ok, next_state, {:decide, "#{first_player} meeting selection"}}
  end
end
