defmodule LemonGames.Matches.DeadlineSweeperTest do
  use ExUnit.Case, async: false

  alias LemonGames.Matches.{DeadlineSweeper, EventStore, Service, Store}

  @actor %{"agent_id" => "deadline_test_agent", "display_name" => "Deadline Tester"}

  setup do
    clear_matches()
    clear_events()

    :ok
  end

  test "expires pending match when accept deadline has passed" do
    {:ok, match} =
      Service.create_match(%{"game_type" => "connect4", "visibility" => "public"}, @actor)

    expired_deadline_match =
      match
      |> Map.put("deadline_at_ms", System.system_time(:millisecond) - 1_000)
      |> Map.put("updated_at_ms", System.system_time(:millisecond))

    :ok = Store.put(match["id"], expired_deadline_match)

    trigger_sweep()

    assert_eventually(fn ->
      updated = Store.get(match["id"])
      updated["status"] == "expired" and updated["result"]["reason"] == "accept_timeout"
    end)
  end

  test "expires active match when turn deadline has passed" do
    {:ok, match} =
      Service.create_match(
        %{
          "game_type" => "connect4",
          "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"},
          "visibility" => "public"
        },
        @actor
      )

    overdue =
      match
      |> Map.put("deadline_at_ms", System.system_time(:millisecond) - 1_000)
      |> Map.put("updated_at_ms", System.system_time(:millisecond))

    :ok = Store.put(match["id"], overdue)

    trigger_sweep()

    assert_eventually(fn ->
      updated = Store.get(match["id"])
      updated["status"] == "expired" and updated["result"]["reason"] == "turn_timeout"
    end)
  end

  defp trigger_sweep do
    assert pid = Process.whereis(DeadlineSweeper)
    send(pid, :sweep)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met within timeout")

  defp clear_matches do
    Enum.each(Store.list(), fn {match_id, _match} -> Store.delete(match_id) end)
  end

  defp clear_events do
    Enum.each(EventStore.list(), fn {{match_id, seq}, _event} ->
      EventStore.delete(match_id, seq)
    end)
  end
end
