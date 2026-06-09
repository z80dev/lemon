defmodule LemonSim.Kernel.EventCoalescer do
  @moduledoc """
  Behaviour for event stream coalescing/filtering before state updates.
  """

  @callback coalesce(events :: [LemonSim.Kernel.Event.t() | map()], opts :: keyword()) ::
              [LemonSim.Kernel.Event.t() | map()]
end
