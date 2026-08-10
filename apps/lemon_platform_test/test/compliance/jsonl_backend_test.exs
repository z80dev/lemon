defmodule LemonPlatformTest.JsonlBackendComplianceTest do
  @moduledoc """
  The kit's `BackendCase` run against the platform's append-only file backend.

  `JsonlBackend` re-encodes terms as JSON, so it is the built-in that most
  stresses the round-trip half of the contract.
  """

  use LemonPlatformTest.BackendCase,
    async: true,
    backend: LemonCore.Store.JsonlBackend,
    backend_opts: {__MODULE__, :backend_opts},
    persistent: true

  def backend_opts(context), do: [path: Path.join(context.tmp_dir, "jsonl")]
end
