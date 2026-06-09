defmodule LemonSim.EventCoalescer do
  @moduledoc false

  @callback coalesce(events :: [LemonSim.Kernel.Event.t() | map()], opts :: keyword()) ::
              [LemonSim.Kernel.Event.t() | map()]
end
