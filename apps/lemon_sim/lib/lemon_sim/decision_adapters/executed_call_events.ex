defmodule LemonSim.DecisionAdapters.ExecutedCallEvents do
  @moduledoc """
  Adapts all executed tool-call result events from a tool-loop decision.

  Tool-loop deciders can return a terminal decision with `"executed_calls"`.
  This adapter preserves every `"event"` / `"events"` payload found in each
  executed call's `result_details`.
  """

  @behaviour LemonSim.DecisionAdapter

  alias LemonSim.{Event, State}

  @impl true
  def to_events(%{} = decision, %State{}, opts) do
    events =
      decision
      |> fetch(:executed_calls, "executed_calls", [])
      |> Enum.flat_map(&events_from_call/1)
      |> Enum.map(&Event.new/1)

    if events == [] and Keyword.get(opts, :require_executed_call_events?, false) do
      {:error, {:missing_events_in_executed_calls, decision}}
    else
      {:ok, events}
    end
  end

  def to_events(other, %State{}, _opts), do: {:error, {:unsupported_decision, other}}

  defp events_from_call(%{} = call) do
    call
    |> fetch(:result_details, "result_details", %{})
    |> events_from_details()
  end

  defp events_from_call(_call), do: []

  defp events_from_details(%{} = details) do
    cond do
      is_list(fetch(details, :events, "events", nil)) ->
        fetch(details, :events, "events", [])

      not is_nil(fetch(details, :event, "event", nil)) ->
        [fetch(details, :event, "event", nil)]

      true ->
        []
    end
  end

  defp events_from_details(_details), do: []

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end
end
