defmodule LemonCore.RouterBridge.NotImplementedError do
  @moduledoc """
  Raised by the default callbacks that `use LemonCore.RouterBridge.Router` and
  `use LemonCore.RouterBridge.RunOrchestrator` inject, so a router that does
  not really handle a call fails visibly through the bridge (as
  `{:error, :query_failed}` for a query or `{:error, :outcome_unknown}` for a
  mutation) instead of answering a made-up value.
  """

  defexception [:module, :function, :arity]

  @impl true
  def message(%__MODULE__{module: module, function: function, arity: arity}) do
    "#{inspect(module)} does not implement #{function}/#{arity}"
  end
end
