defmodule LemonPlatformTest.LocalMemoryProviderComplianceTest do
  @moduledoc """
  The kit's `ProviderCase` run against the built-in SQLite memory provider.
  """

  use LemonPlatformTest.ProviderCase,
    async: false,
    provider: LemonMemory.Providers.Local
end
