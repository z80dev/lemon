defmodule LemonMemory.Provider do
  @moduledoc """
  Behaviour for memory providers: places a finished run's memory is written to.

  `LemonMemory.Providers.Local` (the SQLite store) is built in; additional
  providers — a vector store, a wiki, a remote memory service — register at
  runtime through `LemonMemory.Providers.register_provider/1` and receive every
  finished run's `LemonMemory.Document` through the same fan-out.

  Providers are write targets only. Recall reads the owned local index
  (`LemonMemory.Project.search_history/4`), which applies ownership before its
  result limit; a provider's own search, if it has one, belongs behind its own
  explicitly owner-scoped tools.

  ## Contract

  `LemonPlatformTest.ProviderCase` turns this into a test.

    * **`c:put/2` returns `:ok` or `{:error, reason}`.** It runs on the
      run-finalisation path, so it should be cheap; buffer internally if your
      store is slow.

    * **Unknown options are ignored, not rejected.** The platform adds keys to
      `t:put_opts/0` over time and older providers must keep working.

  `LemonMemory.Providers` isolates provider failures and timeouts. Each call
  runs in its own monitored, unlinked process and is dropped at *this*
  provider's `:timeout_ms` — registering a slow provider never widens anybody
  else's deadline. Exceptions, throws and exits are rescued and logged, and a
  provider process that dies some other way is logged as a failure instead of
  reaching the registry. See `LemonMemory.Providers` for what that isolation
  does *not* cover.
  """

  alias LemonMemory.Document

  @typedoc """
  Options passed to `c:put/2`. Carries `:provider_id`, the id this provider was
  registered under; otherwise provider-defined. Providers must ignore keys they
  do not recognise.
  """
  @type put_opts :: keyword()

  @doc """
  Store a memory document.

  Called on the run-finalisation path, once per finished run, for every enabled
  provider whose scopes include the document's scope. Returns `:ok` or
  `{:error, reason}` — `reason` is logged, never surfaced to the agent, and must
  not be raised.
  """
  @callback put(Document.t(), put_opts()) :: :ok | {:error, term()}
end
