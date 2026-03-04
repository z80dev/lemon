defmodule LemonSim.EventCoalescer do
  @moduledoc """
  Behaviour for event stream coalescing/filtering before state updates.
  """

  @callback coalesce(events :: [LemonSim.Event.t() | map()], opts :: keyword()) ::
              [LemonSim.Event.t() | map()]
end
