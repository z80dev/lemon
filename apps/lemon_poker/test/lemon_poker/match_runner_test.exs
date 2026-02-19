defmodule LemonPoker.MatchRunnerTest do
  use ExUnit.Case, async: true

  alias LemonPoker.{MatchControl, MatchRunner}

  test "emits start and completion events when no hands requested" do
    events =
      collect_events(fn emit ->
        MatchRunner.run(
          [table_id: "test-runner-0", players: 3, hands: 0],
          emit,
          MatchControl.new()
        )
      end)

    assert {:ok, table} = events.result
    assert map_size(table.seats) == 3

    assert [%{type: "match_started"}, %{type: "match_completed"}] =
             Enum.map(events.items, &Map.take(&1, [:type]))
  end

  test "honors stop signal" do
    control = MatchControl.new()
    :ok = MatchControl.stop(control)

    events =
      collect_events(fn emit ->
        MatchRunner.run([table_id: "test-runner-stop", players: 2, hands: 10], emit, control)
      end)

    assert {:stopped, _table} = events.result

    assert Enum.any?(events.items, fn event -> event.type == "match_stopped" end)
  end

  test "applies selected persona per seat in match_started snapshot" do
    events =
      collect_events(fn emit ->
        MatchRunner.run(
          [
            table_id: "test-runner-personas",
            players: 4,
            hands: 0,
            player_personas: ["friendly", "silent", "aggro", "grinder"]
          ],
          emit,
          MatchControl.new()
        )
      end)

    started = Enum.find(events.items, &(&1.type == "match_started"))
    assert started

    assert Enum.map(started.seats, & &1.persona) == ["friendly", "silent", "aggro", "grinder"]
  end

  test "falls back invalid persona selections and accepts case-insensitive values" do
    events =
      collect_events(fn emit ->
        MatchRunner.run(
          [
            table_id: "test-runner-persona-fallback",
            players: 4,
            hands: 0,
            player_personas: ["friendly", "not-real", nil, "SILENT"]
          ],
          emit,
          MatchControl.new()
        )
      end)

    started = Enum.find(events.items, &(&1.type == "match_started"))
    assert started

    assert Enum.map(started.seats, & &1.persona) == ["friendly", "aggro", "friendly", "silent"]
  end

  test "applies per-seat model overrides with global fallback" do
    events =
      collect_events(fn emit ->
        MatchRunner.run(
          [
            table_id: "test-runner-model-overrides",
            players: 4,
            hands: 0,
            model: "claude-sonnet-4.5",
            player_models: ["gpt-5.3-codex", nil, "openai-codex:gpt-5.3-codex", ""]
          ],
          emit,
          MatchControl.new()
        )
      end)

    started = Enum.find(events.items, &(&1.type == "match_started"))
    assert started

    assert Enum.map(started.seats, & &1.model) == [
             "gpt-5.3-codex",
             "claude-sonnet-4.5",
             "openai-codex:gpt-5.3-codex",
             "claude-sonnet-4.5"
           ]
  end

  defp collect_events(fun) do
    parent = self()

    result =
      fun.(fn event ->
        send(parent, {:event, event})
      end)

    items = drain_events([])

    %{result: result, items: items}
  end

  defp drain_events(acc) do
    receive do
      {:event, event} -> drain_events(acc ++ [event])
    after
      0 -> acc
    end
  end
end
