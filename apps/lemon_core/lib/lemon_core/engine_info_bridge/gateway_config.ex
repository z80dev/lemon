defmodule LemonCore.EngineInfoBridge.GatewayConfig do
  @moduledoc """
  The `:gateway_config` capability of `LemonCore.EngineInfoBridge`: a runtime
  that may hold a full-replacement gateway config exposes it here.

  `replacement_config/0` returns the replacement map, or `nil` when the
  canonical config applies.
  """

  @callback replacement_config() :: map() | keyword() | nil
end
