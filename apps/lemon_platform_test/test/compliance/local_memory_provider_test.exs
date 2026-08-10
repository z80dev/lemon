defmodule LemonPlatformTest.LocalMemoryProviderComplianceTest do
  @moduledoc """
  The kit's `ProviderCase` run against the built-in SQLite memory provider.

  The hostile-query set matters most here: `Providers.Local` hands queries to
  SQLite FTS5, which rejects unescaped metacharacters outright, so this suite is
  what keeps the query sanitiser honest.
  """

  use LemonPlatformTest.ProviderCase,
    async: false,
    provider: LemonMemory.Providers.Local
end
