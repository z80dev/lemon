defmodule LemonCore do
  @moduledoc """
  LemonCore provides shared primitives for the Lemon umbrella.

  This app contains cross-cutting concerns that other apps depend on:

  - `LemonCore.Event` - Canonical event envelope for Bus and persistence
  - `LemonCore.Bus` - Process-safe PubSub for cross-app event spine
  - `LemonCore.Id` - ID generation utilities
  - `LemonCore.Idempotency` - Deduplication for operations
  - `LemonCore.Store` - Persistent key-value storage API
  - `LemonCore.Introspection` - Canonical introspection event contract and persistence API
  - `LemonCore.Telemetry` - Telemetry event helpers
  - `LemonCore.Clock` - Time utilities
  - `LemonCore.Config` - Configuration access
  """
end
