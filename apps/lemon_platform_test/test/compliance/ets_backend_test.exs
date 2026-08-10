defmodule LemonPlatformTest.EtsBackendComplianceTest do
  @moduledoc """
  The kit's `BackendCase` run against the platform's in-memory backend.

  `EtsBackend` implements neither optional callback, so this is also the
  suite's proof that a backend which skips `list_recent/3` and `ping/1` still
  passes.
  """

  use LemonPlatformTest.BackendCase,
    async: true,
    backend: LemonCore.Store.EtsBackend
end
