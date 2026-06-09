defmodule LemonSim.Kernel.DecisionAdapter do
  @moduledoc """
  Behaviour for adapting a decider output into simulation events.
  """

  @callback to_events(
              decision :: map(),
              state :: LemonSim.Kernel.State.t(),
              opts :: keyword()
            ) ::
              {:ok, [LemonSim.Kernel.Event.t() | map()]} | {:error, term()}
end
