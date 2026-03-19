defmodule LemonSimUi.WerewolfPlayback do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.State

  @default_hold_ms 900
  @phase_hold_ms 1_700
  @vote_hold_ms 1_800
  @night_action_hold_ms 2_100
  @elimination_hold_ms 3_600
  @game_over_hold_ms 5_200
  @dawn_reveal_hold_ms 5_600

  defstruct display_state: nil,
            queue: [],
            hold_until_ms: 0

  @type t :: %__MODULE__{
          display_state: State.t() | nil,
          queue: [State.t()],
          hold_until_ms: integer()
        }

  @spec new(State.t() | nil, integer()) :: t()
  def new(state, now_ms \\ now_ms()) do
    %__MODULE__{
      display_state: state,
      queue: [],
      hold_until_ms: now_ms
    }
  end

  @spec enqueue(t(), State.t() | nil) :: t()
  def enqueue(%__MODULE__{} = playback, nil), do: playback

  def enqueue(%__MODULE__{} = playback, %State{} = state) do
    if enqueue_state?(playback, state) do
      %{playback | queue: playback.queue ++ [state]}
    else
      playback
    end
  end

  @spec next_delay_ms(t(), integer()) :: non_neg_integer() | nil
  def next_delay_ms(playback, now_ms \\ now_ms())

  def next_delay_ms(%__MODULE__{queue: []}, _now_ms), do: nil

  def next_delay_ms(%__MODULE__{hold_until_ms: hold_until_ms}, now_ms) do
    max(hold_until_ms - now_ms, 0)
  end

  @spec advance(t(), integer()) :: {t(), non_neg_integer() | nil}
  def advance(%__MODULE__{queue: []} = playback, _now_ms), do: {playback, nil}

  def advance(
        %__MODULE__{display_state: prev_state, queue: [next_state | rest]} = playback,
        now_ms
      ) do
    hold_ms = dwell_ms(prev_state, next_state)

    updated =
      %{
        playback
        | display_state: next_state,
          queue: rest,
          hold_until_ms: now_ms + hold_ms
      }

    {updated, hold_ms}
  end

  @spec queue_depth(t()) :: non_neg_integer()
  def queue_depth(%__MODULE__{queue: queue}), do: length(queue)

  defp enqueue_state?(%__MODULE__{} = playback, %State{} = state) do
    case last_known_state(playback) do
      nil ->
        true

      %State{} = last_state ->
        cond do
          state.version > last_state.version ->
            true

          state.version < last_state.version ->
            false

          state_signature(state) == state_signature(last_state) ->
            false

          true ->
            true
        end
    end
  end

  defp last_known_state(%__MODULE__{queue: []} = playback), do: playback.display_state
  defp last_known_state(%__MODULE__{queue: queue}), do: List.last(queue)

  defp state_signature(%State{} = state) do
    :erlang.phash2(
      {state.version, state.world, state.recent_events, state.plan_history, state.meta}
    )
  end

  defp dwell_ms(nil, _next_state), do: @default_hold_ms

  defp dwell_ms(%State{} = prev_state, %State{} = next_state) do
    cond do
      game_over?(next_state) ->
        @game_over_hold_ms

      new_last_words = latest_last_words(prev_state, next_state) ->
        dialogue_hold_ms(get_text(new_last_words, :statement), min_ms: 3_800, max_ms: 8_400)

      new_wolf_chat = latest_wolf_chat(prev_state, next_state) ->
        dialogue_hold_ms(get_text(new_wolf_chat, :message), min_ms: 3_400, max_ms: 7_600)

      new_meeting = latest_meeting_message(prev_state, next_state) ->
        dialogue_hold_ms(get_text(new_meeting, :message), min_ms: 3_000, max_ms: 6_800)

      new_statement = latest_discussion_entry(prev_state, next_state) ->
        statement_type = get_text(new_statement, :type)

        dialogue_hold_ms(
          get_text(new_statement, :statement),
          min_ms: if(statement_type == "accusation", do: 3_800, else: 3_200),
          max_ms: if(statement_type == "accusation", do: 8_000, else: 7_200)
        )

      phase_changed?(prev_state, next_state) ->
        phase_hold_ms(phase(prev_state), phase(next_state))

      elimination_added?(prev_state, next_state) ->
        @elimination_hold_ms

      village_event_changed?(prev_state, next_state) ->
        4_000

      evidence_changed?(prev_state, next_state) ->
        2_600

      wanderer_changed?(prev_state, next_state) ->
        2_400

      night_action_changed?(prev_state, next_state) ->
        @night_action_hold_ms

      votes_changed?(prev_state, next_state) ->
        @vote_hold_ms

      active_actor(prev_state) != active_actor(next_state) ->
        950

      true ->
        @default_hold_ms
    end
  end

  defp phase_hold_ms("night", next_phase)
       when next_phase in ["meeting_selection", "day_discussion"],
       do: @dawn_reveal_hold_ms

  defp phase_hold_ms("wolf_discussion", "night"), do: 1_500
  defp phase_hold_ms("meeting_selection", "private_meeting"), do: 1_900
  defp phase_hold_ms("private_meeting", "day_discussion"), do: 2_200
  defp phase_hold_ms("day_discussion", "day_voting"), do: 2_000
  defp phase_hold_ms("runoff_discussion", "runoff_voting"), do: 2_000
  defp phase_hold_ms("day_voting", "runoff_discussion"), do: 2_300
  defp phase_hold_ms("runoff_voting", "last_words_vote"), do: 2_600
  defp phase_hold_ms("day_voting", "last_words_vote"), do: 2_600
  defp phase_hold_ms("last_words_vote", "night"), do: 2_200
  defp phase_hold_ms(_, "game_over"), do: @game_over_hold_ms
  defp phase_hold_ms(_, _), do: @phase_hold_ms

  defp dialogue_hold_ms(text, opts) do
    min_ms = Keyword.fetch!(opts, :min_ms)
    max_ms = Keyword.fetch!(opts, :max_ms)
    words = count_words(text)

    ms =
      cond do
        words <= 0 -> min_ms
        true -> 2_300 + words * 170
      end

    ms
    |> max(min_ms)
    |> min(max_ms)
  end

  defp latest_wolf_chat(prev_state, next_state) do
    latest_added_entry(
      list_world(prev_state, :wolf_chat_transcript),
      list_world(next_state, :wolf_chat_transcript)
    )
  end

  defp latest_discussion_entry(prev_state, next_state) do
    latest_added_entry(
      list_world(prev_state, :discussion_transcript),
      list_world(next_state, :discussion_transcript)
    )
  end

  defp latest_meeting_message(prev_state, next_state) do
    latest_added_entry(
      list_world(prev_state, :current_meeting_messages),
      list_world(next_state, :current_meeting_messages)
    )
  end

  defp latest_last_words(prev_state, next_state) do
    latest_added_entry(list_world(prev_state, :last_words), list_world(next_state, :last_words))
  end

  defp latest_added_entry(prev_list, next_list) when is_list(prev_list) and is_list(next_list) do
    if length(next_list) > length(prev_list), do: List.last(next_list)
  end

  defp elimination_added?(prev_state, next_state) do
    length(list_world(next_state, :elimination_log)) >
      length(list_world(prev_state, :elimination_log))
  end

  defp evidence_changed?(prev_state, next_state) do
    length(list_world(next_state, :evidence_tokens)) >
      length(list_world(prev_state, :evidence_tokens))
  end

  defp wanderer_changed?(prev_state, next_state) do
    length(list_world(next_state, :wanderer_results)) >
      length(list_world(prev_state, :wanderer_results))
  end

  defp village_event_changed?(prev_state, next_state) do
    world_value(prev_state, :current_village_event) !=
      world_value(next_state, :current_village_event) and
      not is_nil(world_value(next_state, :current_village_event))
  end

  defp night_action_changed?(prev_state, next_state) do
    map_world(prev_state, :night_actions) != map_world(next_state, :night_actions)
  end

  defp votes_changed?(prev_state, next_state) do
    map_world(prev_state, :votes) != map_world(next_state, :votes)
  end

  defp game_over?(state) do
    world_value(state, :status) == "game_over" or not is_nil(world_value(state, :winner))
  end

  defp phase_changed?(prev_state, next_state), do: phase(prev_state) != phase(next_state)
  defp phase(state), do: world_value(state, :phase) || "unknown"
  defp active_actor(state), do: world_value(state, :active_actor_id)

  defp list_world(%State{} = state, key) do
    state |> world_value(key) |> List.wrap()
  end

  defp map_world(%State{} = state, key) do
    case world_value(state, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp world_value(%State{world: world}, key), do: MapHelpers.get_key(world, key)

  defp get_text(map, key) when is_map(map) do
    map
    |> MapHelpers.get_key(key)
    |> to_string()
  end

  defp get_text(_value, _key), do: ""

  defp count_words(text) do
    text
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
