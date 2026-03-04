defmodule LemonSim.DecisionSignal do
  @moduledoc """
  Decision gating signal returned by updater/coalescing stages.
  """

  @type t :: :skip | :decide | {:decide, String.t()}

  @spec decide?(t()) :: boolean()
  def decide?(signal), do: match?(:decide, signal) or match?({:decide, _}, signal)
end
