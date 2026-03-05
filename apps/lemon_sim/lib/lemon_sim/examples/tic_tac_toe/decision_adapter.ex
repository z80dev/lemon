defmodule LemonSim.Examples.TicTacToe.DecisionAdapter do
  @moduledoc false

  @behaviour LemonSim.DecisionAdapter

  alias LemonSim.State

  @impl true
  def to_events(%{"type" => "tool_call", "result_details" => details}, %State{}, _opts)
      when is_map(details) do
    case Map.get(details, "event") || Map.get(details, :event) do
      nil -> {:error, {:missing_event_in_decision, details}}
      event -> {:ok, [event]}
    end
  end

  def to_events(other, %State{}, _opts), do: {:error, {:unsupported_decision, other}}
end
