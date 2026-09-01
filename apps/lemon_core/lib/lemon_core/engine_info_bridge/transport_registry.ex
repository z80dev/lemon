defmodule LemonCore.EngineInfoBridge.TransportRegistry do
  @moduledoc """
  The `:transport_registry` capability of `LemonCore.EngineInfoBridge`: ops
  introspection over the transports an execution runtime has configured.
  """

  @callback list_transports() :: [term()]
  @callback enabled_transports() :: [{term(), module()}]
  @callback get_transport(id :: term()) :: module() | nil
end
