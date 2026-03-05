defmodule LemonSim.DecisionAdapter do
  @moduledoc """
  Behaviour for adapting a decider output into simulation events.
  """

  @callback to_events(
              decision :: map(),
              state :: LemonSim.State.t(),
              opts :: keyword()
            ) ::
              {:ok, [LemonSim.Event.t() | map()]} | {:error, term()}
end
