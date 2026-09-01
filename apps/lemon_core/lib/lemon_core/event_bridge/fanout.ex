defmodule LemonCore.EventBridge.Fanout do
  @moduledoc """
  What `LemonCore.EventBridge.configure/1` accepts: a module that forwards a
  run's bus events to external clients on request.

  The reference implementation is `LemonControlPlane.EventBridge`, which
  subscribes WebSocket clients to `run:<id>` topics. Both callbacks are
  idempotent and total: subscribing twice or unsubscribing an unknown run is
  `:ok`.
  """

  @callback subscribe_run(run_id :: binary()) :: :ok
  @callback unsubscribe_run(run_id :: binary()) :: :ok
end
