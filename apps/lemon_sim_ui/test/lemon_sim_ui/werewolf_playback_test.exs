defmodule LemonSimUi.WerewolfPlaybackTest do
  use ExUnit.Case, async: true

  alias LemonSim.State
  alias LemonSimUi.WerewolfPlayback

  test "wolf chat gets a readable dwell before the next phase" do
    state0 = state(0, %{phase: "wolf_discussion", active_actor_id: "Cora"})

    state1 =
      state(1, %{
        phase: "wolf_discussion",
        active_actor_id: "Dane",
        wolf_chat_transcript: [
          %{
            player: "Cora",
            message:
              "Keep suspicion on Alice tonight. If the village fractures tomorrow, we get another free day."
          }
        ]
      })

    state2 = state(2, %{phase: "night", active_actor_id: "Cora"})

    playback =
      WerewolfPlayback.new(state0, 1_000)
      |> WerewolfPlayback.enqueue(state1)
      |> WerewolfPlayback.enqueue(state2)

    assert WerewolfPlayback.queue_depth(playback) == 2

    {after_first, hold_ms} = WerewolfPlayback.advance(playback, 1_000)

    assert after_first.display_state.version == 1
    assert hold_ms >= 3_400
    assert WerewolfPlayback.next_delay_ms(after_first, 1_000) == hold_ms
  end

  test "same-version world enrichments still enqueue when the snapshot changed" do
    base_state =
      state(7, %{
        phase: "day_discussion",
        character_profiles: %{}
      })

    enriched_state =
      state(7, %{
        phase: "day_discussion",
        character_profiles: %{
          "Alice" => %{"full_name" => "Elara Thornberry"}
        }
      })

    playback =
      WerewolfPlayback.new(base_state, 2_000)
      |> WerewolfPlayback.enqueue(enriched_state)

    assert WerewolfPlayback.queue_depth(playback) == 1

    {after_enrichment, _hold_ms} = WerewolfPlayback.advance(playback, 2_000)

    assert after_enrichment.display_state.world.character_profiles["Alice"]["full_name"] ==
             "Elara Thornberry"
  end

  test "night to dawn reveal gets a long cinematic pause" do
    night_state = state(3, %{phase: "night", active_actor_id: "Cora"})
    dawn_state = state(4, %{phase: "meeting_selection", active_actor_id: "Alice"})

    playback =
      WerewolfPlayback.new(night_state, 5_000)
      |> WerewolfPlayback.enqueue(dawn_state)

    {_after_dawn, hold_ms} = WerewolfPlayback.advance(playback, 5_000)

    assert hold_ms >= 5_600
  end

  defp state(version, overrides) do
    world =
      base_world()
      |> Map.merge(overrides)

    State.new(
      sim_id: "werewolf-playback-test",
      version: version,
      world: world
    )
  end

  defp base_world do
    %{
      phase: "night",
      status: "in_progress",
      winner: nil,
      active_actor_id: "Alice",
      players: %{
        "Alice" => %{role: "villager", status: "alive"},
        "Bram" => %{role: "doctor", status: "alive"},
        "Cora" => %{role: "werewolf", status: "alive"},
        "Dane" => %{role: "seer", status: "alive"}
      },
      discussion_transcript: [],
      wolf_chat_transcript: [],
      current_meeting_messages: [],
      last_words: [],
      elimination_log: [],
      evidence_tokens: [],
      wanderer_results: [],
      current_village_event: nil,
      night_actions: %{},
      votes: %{},
      character_profiles: %{}
    }
  end
end
