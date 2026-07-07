defmodule LemonSim.Examples.TcgShop.Updaters.Observations do
  @moduledoc false

  alias LemonSim.Kernel.State

  import LemonSim.Examples.TcgShop.Updaters.Support

  def append_only(%State{} = state, event) do
    # :skip, not :decide — support observations land in the same ingest
    # batch as the terminal action's event, and Runner.ingest_events halts
    # on the first decide signal, which would drop the terminal event.
    {:ok, State.append_event(state, event), :skip}
  end

  def apply_researched_market(%State{} = state, event) do
    query = get(event.payload, "query", "")
    day = get(state.world, :day_number, 1)
    pulse = List.last(get(state.world, :market_pulses, []))

    entry = %{
      day: day,
      query: query,
      pulse: pulse,
      notes:
        get(event.payload, "notes", [
          "Sealed margins depend on allocation and cash discipline.",
          "Singles demand decays quickly after metagame spikes.",
          "Events convert players into accessory and singles buyers."
        ]),
      source: "local_market_research",
      confidence: "operating_estimate"
    }

    next =
      state
      |> State.update_world(fn world ->
        Map.update(world, :research_history, [entry], &(&1 ++ [entry]))
      end)
      |> State.append_event(event)

    {:ok, next, :skip}
  end
end
