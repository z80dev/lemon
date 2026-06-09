defmodule LemonSim.GameHelpers.EventHelpers do
  @moduledoc false

  defdelegate event_kind(event), to: LemonSim.Examples.Helpers.EventHelpers
  defdelegate event_payload(event), to: LemonSim.Examples.Helpers.EventHelpers
  defdelegate event_player_id(event), to: LemonSim.Examples.Helpers.EventHelpers
  defdelegate put_payload(event, new_payload), to: LemonSim.Examples.Helpers.EventHelpers
end
