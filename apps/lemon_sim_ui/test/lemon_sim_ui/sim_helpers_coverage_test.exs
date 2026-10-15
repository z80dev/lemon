defmodule LemonSimUi.SimHelpersCoverageTest do
  use ExUnit.Case, async: true

  alias LemonSim.Kernel.{Event, State}
  alias LemonSimUi.SimHelpers

  test "infers domains from atom and string keyed worlds" do
    assert SimHelpers.infer_domain_type(state(%{"arena_agents" => []})) == :vending_bench
    assert SimHelpers.infer_domain_type(state(%{"machine" => %{}})) == :vending_bench
    assert SimHelpers.infer_domain_type(state(%{players: %{}})) == :werewolf

    # Poker also carries a :players map, so its :table/:player_stats check
    # must win over the werewolf fallthrough.
    assert SimHelpers.infer_domain_type(state(%{table: %{}, player_stats: %{}, players: %{}})) ==
             :poker

    assert SimHelpers.infer_domain_type(state(%{})) == :unknown
  end

  test "summaries render terminal and active domain state" do
    assert summary(%{board: [], current_player: "X", move_count: 3}) ==
             "X's turn (3 moves)"

    assert summary(%{board: [], winner: "O"}) == "Winner: O"

    assert summary(%{machine: %{}, day_number: 4, max_days: 14, bank_balance: 123.4}) ==
             "Day 4/14 - $123.40"

    assert summary(%{machine: %{}, day_number: 6, status: "bankrupt"}) == "Bankrupt (Day 6)"
  end

  test "sim summary includes event count and last event timestamp" do
    state =
      State.new(
        sim_id: "ui-summary",
        version: 7,
        world: %{phase: "night", day_number: 2, status: "in_progress"},
        recent_events: [
          Event.new(kind: "first", ts_ms: 100),
          Event.new(kind: "second", ts_ms: 250)
        ]
      )

    assert SimHelpers.sim_summary(state) == %{
             sim_id: "ui-summary",
             version: 7,
             domain_type: :werewolf,
             status: "in_progress",
             finished?: false,
             event_count: 2,
             last_activity: 250,
             world_summary: "Day 2 - Phase: night"
           }
  end

  test "summaries mark every scenario's terminal status as finished" do
    for world <- [
          %{board: [], status: "won", winner: "X"},
          %{board: [], status: "draw"},
          %{machine: %{}, day_number: 6, status: "bankrupt"},
          %{machine: %{}, day_number: 30, status: "complete"},
          %{players: %{}, status: "game_over", winner: "villagers"},
          %{table: %{}, player_stats: %{}, players: %{}, status: "game_over"}
        ] do
      assert SimHelpers.sim_summary(state(world)).finished?, inspect(world)
    end

    refute SimHelpers.sim_summary(state(%{board: [], status: "in_progress"})).finished?
  end

  test "labels, status colors, and timestamps have deterministic fallbacks" do
    assert SimHelpers.domain_label(:vending_bench) == "Vending Bench"
    assert SimHelpers.domain_label(:poker) == "Poker"
    assert SimHelpers.domain_label(:missing) == "Unknown"
    assert SimHelpers.domain_badge_color(:missing) =~ "gray"
    assert SimHelpers.status_color(nil) == "text-gray-500"
    assert SimHelpers.format_ts(nil) == "--"
  end

  defp summary(world) do
    %{world_summary: world_summary} = SimHelpers.sim_summary(state(world))
    world_summary
  end

  defp state(world) do
    State.new(sim_id: "ui-helper-test", world: world)
  end
end
