defmodule LemonPlatformTest.EtsBackendComplianceTest do
  @moduledoc """
  The kit's `BackendCase` run against the platform's in-memory backend.

  `EtsBackend` implements optional `compare_and_delete_many/2` but omits
  `list_recent/3` and `ping/1`, so this is also the suite's proof that a backend
  which skips either fallback-backed callback still passes.
  """

  use LemonPlatformTest.BackendCase,
    async: true,
    backend: LemonCore.Store.EtsBackend
end
