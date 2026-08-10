if Code.ensure_loaded?(Exqlite.Sqlite3) do
  defmodule LemonPlatformTest.SqliteBackendComplianceTest do
    @moduledoc """
    The kit's `BackendCase` run against the platform's durable backend.

    `:exqlite` is an optional dependency of `lemon_core`, so this module only
    exists when it is available — the same guard a third-party backend built on
    an optional driver would need.
    """

    use LemonPlatformTest.BackendCase,
      async: true,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: {__MODULE__, :backend_opts},
      persistent: true

    def backend_opts(context), do: [path: Path.join(context.tmp_dir, "compliance.sqlite3")]
  end
end
