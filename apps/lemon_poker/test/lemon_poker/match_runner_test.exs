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
