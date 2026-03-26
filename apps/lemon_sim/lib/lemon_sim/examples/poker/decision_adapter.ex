defmodule LemonSim.Examples.Poker.DecisionAdapter do
  @moduledoc false

  @behaviour LemonSim.DecisionAdapter

  alias LemonSim.{Event, State}

  @impl true
  def to_events(%{} = decision, %State{}, _opts) do
    events =
      decision
      |> Map.get("executed_calls", [])
      |> Enum.flat_map(&extract_events/1)
      |> Enum.map(&Event.new/1)

    if events == [] do
      {:error, {:missing_events_in_executed_calls, decision}}
    else
      {:ok, events}
    end
  end

  def to_events(other, %State{}, _opts), do: {:error, {:unsupported_decision, other}}

  defp extract_events(call) when is_map(call) do
    details = Map.get(call, :result_details) || Map.get(call, "result_details") || %{}

    cond do
      is_list(fetch(details, :events, "events", nil)) ->
        fetch(details, :events, "events", [])

      not is_nil(fetch(details, :event, "event", nil)) ->
        [fetch(details, :event, "event", nil)]

      true ->
        []
    end
  end

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end
end
