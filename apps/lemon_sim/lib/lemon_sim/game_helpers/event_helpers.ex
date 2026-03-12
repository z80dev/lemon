defmodule LemonSim.GameHelpers.EventHelpers do
  @moduledoc """
  Shared event introspection helpers for game modules.

  Provides uniform access to event fields regardless of whether the event
  uses atom or string keys.
  """

  def event_kind(%{kind: kind}), do: to_string(kind)
  def event_kind(%{"kind" => kind}), do: to_string(kind)
  def event_kind(_), do: ""

  def event_payload(%{payload: p}) when is_map(p), do: p
  def event_payload(%{"payload" => p}) when is_map(p), do: p
  def event_payload(_), do: %{}

  def event_player_id(event) do
    p = event_payload(event)
    Map.get(p, :player_id, Map.get(p, "player_id"))
  end

  def put_payload(%{payload: _} = event, new_payload), do: %{event | payload: new_payload}

  def put_payload(%{"payload" => _} = event, new_payload),
    do: Map.put(event, "payload", new_payload)

  def put_payload(event, _), do: event
end
