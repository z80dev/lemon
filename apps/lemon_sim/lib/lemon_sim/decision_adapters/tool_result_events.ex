defmodule LemonSim.DecisionAdapters.ToolResultEvents do
  @moduledoc """
  Default decision adapter for tool results containing event payloads.

  This adapter expects the terminal decision to be a tool call whose
  `result_details` contains either:

  - `"event"` / `:event` => one event
  - `"events"` / `:events` => a list of events
  """

  @behaviour LemonSim.DecisionAdapter

  alias LemonSim.{Event, State}

  @impl true
  def to_events(%{"type" => "tool_call", "result_details" => details}, %State{}, _opts)
      when is_map(details) do
    cond do
      is_list(fetch(details, :events, "events", nil)) ->
        {:ok, details |> fetch(:events, "events", []) |> Enum.map(&Event.new/1)}

      not is_nil(fetch(details, :event, "event", nil)) ->
        {:ok, [details |> fetch(:event, "event", nil) |> Event.new()]}

      true ->
        {:error, {:missing_event_in_decision, details}}
    end
  end

  def to_events(other, %State{}, _opts), do: {:error, {:unsupported_decision, other}}

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end
end
