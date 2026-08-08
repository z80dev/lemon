defmodule LemonSim.Examples.PhilosopherChat.DecisionAdapter do
  @moduledoc """
  Decision adapter for PhilosopherChat turns.

  The terminal tool call usually carries an event (a `speak` call). Memory
  tool calls are legitimate terminal actions too — their side effects are
  already persisted to the agent's memory root, so they yield no world events.
  """

  @behaviour LemonSim.Kernel.DecisionAdapter

  alias LemonSim.Kernel.{Event, State}

  @impl true
  def to_events(%{"type" => "tool_call", "result_details" => details}, %State{}, _opts)
      when is_map(details) do
    cond do
      is_list(fetch(details, :events, "events", nil)) ->
        {:ok, details |> fetch(:events, "events", []) |> Enum.map(&Event.new/1)}

      not is_nil(fetch(details, :event, "event", nil)) ->
        {:ok, [details |> fetch(:event, "event", nil) |> Event.new()]}

      true ->
        {:ok, []}
    end
  end

  def to_events(other, %State{}, _opts), do: {:error, {:unsupported_decision, other}}

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end
end
