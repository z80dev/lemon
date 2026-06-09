defmodule LemonSim.Event do
  @moduledoc false

  @type t :: LemonSim.Kernel.Event.t()
  @type kind :: LemonSim.Kernel.Event.kind()

  defdelegate new(attrs), to: LemonSim.Kernel.Event
  defdelegate new(kind, payload), to: LemonSim.Kernel.Event
  defdelegate new(kind, payload, meta), to: LemonSim.Kernel.Event
end
