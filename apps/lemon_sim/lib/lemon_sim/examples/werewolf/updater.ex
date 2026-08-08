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
    with {:ok, event} <- normalize_event(raw_event),
         :ok <- validate_payload(event) do
      apply_normalized_event(state, event)
    end
  end

  defp apply_normalized_event(state, event) do
    result =
      case validate_thought(event) do
        :ok ->
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
            "decision_missed" -> apply_decision_missed(state, event)
            _ -> {:error, {:invalid_event_kind, event.kind}}
          end

        {:error, reason} ->
          player_id = Map.get(event.payload, "player_id") || Map.get(event.payload, :player_id)
          reject_action(state, event, player_id, reason)
      end

    case result do
      {:ok, next_state, signal} ->
        if rejected?(next_state) do
          {:ok, keep_rejection_only(state, next_state), signal}
        else
          {:ok, maybe_store_thought(next_state, event, state.world), signal}
        end

      other ->
        other
    end
  end

  defp normalize_event(raw_event) when is_map(raw_event) or is_list(raw_event) do
    {:ok, Events.normalize(raw_event)}
  rescue
    _ -> {:error, :invalid_event}
  end

  defp normalize_event(_raw_event), do: {:error, :invalid_event}

  defp validate_payload(%{payload: payload}) when is_map(payload), do: :ok

  defp validate_payload(event) do
    {:error, {:invalid_event_payload, safe_event_kind(event.kind)}}
  end

  defp safe_event_kind(kind) when is_binary(kind) and byte_size(kind) <= 100 do
    if String.valid?(kind), do: kind, else: "event"
  end

  defp safe_event_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_event_kind(_kind), do: "event"

  defp rejected?(state) do
    case List.last(state.recent_events) do
      %{kind: "action_rejected"} -> true
      _ -> false
    end
  end

  defp keep_rejection_only(previous_state, rejected_state) do
    rejection = List.last(rejected_state.recent_events)
    events = Enum.take(previous_state.recent_events ++ [rejection], -25)
    %{rejected_state | recent_events: events}
  end

  defp validate_thought(event) do
    case Map.get(event.payload, "thought") || Map.get(event.payload, :thought) do
      nil -> :ok
      thought -> ensure_text(thought)
    end
  end

  defp apply_decision_missed(state, event) do
    missed = get(state.world, :missed_decisions, [])

    entry = %{
      player: get(event.payload, :player_id),
      day: get(state.world, :day_number, 1),
      phase: get(state.world, :phase),
      reason: get(event.payload, :reason),
      fallback_action: get(event.payload, :fallback_action)
    }

    next_state =
      state
      |> State.put_world(world_updates(state.world, %{missed_decisions: missed ++ [entry]}))
      |> State.append_event(event)

    {:ok, next_state, :skip}
  end

  defp maybe_store_thought(state, event, action_world) do
    thought = Map.get(event.payload, "thought") || Map.get(event.payload, :thought)
    player_id = Map.get(event.payload, "player_id") || Map.get(event.payload, :player_id)

    if is_binary(thought) and String.trim(thought) != "" and byte_size(thought) <= 2_000 and
         is_binary(player_id) do
      journals = get(state.world, :journals, %{})
      player_journal = Map.get(journals, player_id, [])

      entry = %{
        day: get(action_world, :day_number, 1),
        phase: get(action_world, :phase),
        thought: String.trim(thought)
      }

      new_journals = Map.put(journals, player_id, player_journal ++ [entry])
      State.put_world(state, world_updates(state.world, %{journals: new_journals}))
    else
      state
    end
  end
end
