defmodule LemonTcg.Agent.Updater do
  @moduledoc """
  Applies live-session events to the kernel state mirror.

  Unlike sim updaters, this one mutates nothing: the desk already executed
  the real action inside the tool call. Events only update the mirror the
  projector reads — turn counter, bounded action history, and a fresh desk
  snapshot after anything that could have changed the portfolio.
  """

  @behaviour LemonSim.Kernel.Updater

  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.{Event, State}
  alias LemonTcg.Desk

  @observation_kinds ~w(tcg_live_checked_dashboard tcg_live_checked_floor tcg_live_checked_listings)
  @action_kinds ~w(tcg_live_bought tcg_live_sold tcg_live_halted tcg_live_action_rejected)
  @max_action_history 50

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Event.new(raw_event)
    kind = to_string(event.kind)

    cond do
      kind in @observation_kinds ->
        # :skip, not :decide — Runner.ingest_events halts on the first
        # decide signal, and observation events precede the terminal
        # action's event within a single decision batch.
        {:ok, State.append_event(state, event), :skip}

      kind in @action_kinds ->
        state =
          state
          |> record_action(event, kind)
          |> refresh_snapshot()
          |> State.append_event(event)

        {:ok, state, {:decide, "action recorded"}}

      kind == "tcg_live_waited" ->
        state =
          state
          |> State.update_world(&advance_turn/1)
          |> refresh_snapshot()
          |> State.append_event(event)

        {:ok, state, {:decide, "turn advanced"}}

      kind == "tcg_live_session_closed" ->
        state =
          state
          |> State.update_world(&Map.put(&1, :status, "complete"))
          |> State.append_event(event)

        {:ok, state, {:decide, "session closed"}}

      true ->
        {:error, {:invalid_tcg_live_event, event.kind}}
    end
  end

  defp record_action(state, event, kind) do
    if kind == "tcg_live_action_rejected" do
      State.update_world(state, fn world ->
        world
        |> Map.update(:invalid_action_count, 1, &(&1 + 1))
        |> append_action(event, kind)
      end)
    else
      State.update_world(state, &append_action(&1, event, kind))
    end
  end

  defp append_action(world, event, kind) do
    entry = %{kind: kind, payload: event.payload, ts_ms: event.ts_ms}

    Map.update(world, :action_history, [entry], fn history ->
      Enum.take(history ++ [entry], -@max_action_history)
    end)
  end

  defp advance_turn(world) do
    turn = MapHelpers.get_key(world, :turn) || 1
    max_turns = MapHelpers.get_key(world, :max_turns) || 1
    next_turn = turn + 1

    world
    |> Map.put(:turn, next_turn)
    |> Map.put(:status, if(next_turn > max_turns, do: "complete", else: "in_progress"))
  end

  defp refresh_snapshot(%State{} = state) do
    case Map.get(state.meta, :desk) do
      nil -> state
      desk -> State.put_world(state, %{snapshot: Desk.snapshot(desk)})
    end
  end
end
