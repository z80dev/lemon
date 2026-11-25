defmodule LemonGateway do
  @moduledoc """
  Opt-in gateway ingress: the webhook, SMS and voice surfaces.

  The gateway does not execute runs. Each ingress surface submits a
  `LemonCore.RunRequest` through `LemonCore.RouterBridge`; the router's
  `LemonRouter.RunProcess` owns the run from admission to completion. Ingress
  starts only when `[gateway.ingress] enabled` is true.
  """
end
