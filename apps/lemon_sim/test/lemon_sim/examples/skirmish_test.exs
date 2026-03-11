defmodule LemonSim.Examples.SkirmishTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.Skirmish

  test "example runs to completion with scripted attacks" do
    {:ok, moves} =
      Agent.start_link(fn ->
        [
          %{"attacker_id" => "red_1", "target_id" => "blue_1"},
          %{"attacker_id" => "red_1", "target_id" => "blue_1"},
          %{"attacker_id" => "blue_1", "target_id" => "red_1"},
          %{"attacker_id" => "blue_1", "target_id" => "red_1"},
          %{"attacker_id" => "red_1", "target_id" => "blue_1"}
        ]
      end)

    complete_fn = fn _model, _context, _stream_opts ->
      move =
        Agent.get_and_update(moves, fn
          [next | rest] -> {next, rest}
          [] -> {nil, []}
        end)

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "skirmish-#{System.unique_integer([:positive])}",
             name: "attack_unit",
             arguments: move
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    # Use a small 5x5 world with 1v1 for predictable test (same as old defaults)
    small_world = %{
      map: %{
        width: 5,
        height: 5,
        cover: [%{x: 1, y: 1}, %{x: 3, y: 3}],
        walls: [],
        water: [],
        high_ground: []
      },
      units: %{
        "red_1" => %{
          team: "red", hp: 8, max_hp: 8, ap: 2, max_ap: 2,
          pos: %{x: 0, y: 0}, status: "alive", cover?: false,
          attack_range: 2, attack_damage: 3, attack_chance: 100,
          sight_range: 4, class: "soldier", abilities: []
        },
        "blue_1" => %{
          team: "blue", hp: 8, max_hp: 8, ap: 2, max_ap: 2,
          pos: %{x: 2, y: 0}, status: "alive", cover?: false,
          attack_range: 2, attack_damage: 3, attack_chance: 100,
          sight_range: 4, class: "soldier", abilities: []
        }
      },
      turn_order: ["red_1", "blue_1"],
      active_actor_id: "red_1",
      phase: "main",
      round: 1,
      rng_seed: 5,
      winner: nil,
      status: "in_progress",
      kill_feed: []
    }

    state = LemonSim.State.new(
      sim_id: "test_skirmish",
      world: small_world,
      intent: %{goal: "Win the skirmish"},
      plan_history: []
    )

    output =
      capture_io(fn ->
        assert {:ok, final_state} =
                 LemonSim.Runner.run_until_terminal(
                   state,
                   Skirmish.modules(),
                   model: fake_model(),
                   complete_fn: complete_fn,
                   stream_options: %{},
                   persist?: false,
                   driver_max_turns: 10,
                   terminal?: fn s -> LemonCore.MapHelpers.get_key(s.world, :status) == "won" end,
                   on_before_step: fn _turn, _state -> :ok end,
                   on_after_step: fn _turn, _result -> :ok end,
                   section_builders: %{},
                   section_order: [:world_state, :recent_events, :available_actions, :decision_contract]
                 )

        assert final_state.world.status == "won"
        assert final_state.world.winner == "red"
        assert final_state.world.round == 2
        assert final_state.world.units["blue_1"].status == "dead"
        assert final_state.world.units["red_1"].hp == 2
      end)

    assert is_binary(output)
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end
end
