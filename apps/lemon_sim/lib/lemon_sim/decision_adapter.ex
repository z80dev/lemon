defmodule LemonSim.DecisionAdapter do
  @moduledoc false

  @callback to_events(
              decision :: map(),
              state :: LemonSim.Kernel.State.t(),
              opts :: keyword()
            ) ::
              {:ok, [LemonSim.Kernel.Event.t() | map()]} | {:error, term()}
end
