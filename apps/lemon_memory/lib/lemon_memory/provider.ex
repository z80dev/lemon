defmodule LemonMemory.Provider do
  @moduledoc """
  Behaviour for searchable memory providers.

  A provider is a place an agent's past work can be written to and searched.
  `LemonMemory.Providers.Local` (SQLite FTS) is built in; additional providers —
  a vector store, a wiki, an issue tracker — register at runtime through
  `LemonMemory.Providers.register_provider/1` and are queried through the same
  fan-out.

  Providers receive the same scoped search options as `LemonMemory.SessionSearch`
  and return `LemonMemory.Document` structs.

  ## Contract

  `LemonPlatformTest.ProviderCase` turns each of these into a test.

    * **`c:search/2` returns a plain list of `LemonMemory.Document` structs.**
      Not `{:ok, docs}`, not `nil`, not a stream. `LemonMemory.Providers`
      discards any result that is not a list of documents and treats it as a
      provider failure.

    * **`c:search/2` must not raise for user input.** Queries come from agents
      and from people: quotes, wildcards, boolean operators, emoji, ten-thousand
      character pastes. Full-text engines reject many of those outright, so
      sanitise rather than pass through — `LemonMemory.Store` strips FTS5
      metacharacters and AND-joins the remaining terms. Return `[]` for a query
      you cannot serve.

    * **Unknown options are ignored, not rejected.** The platform adds keys to
      `t:search_opts/0` over time and older providers must keep working.

    * **`c:put/2` returns `:ok` or `{:error, reason}`.** It runs on the
      run-finalisation path, so it should be cheap; buffer internally if your
      store is slow.

  `LemonMemory.Providers` isolates provider failures and timeouts. Each call
  runs in its own monitored, unlinked process and is dropped at *this*
  provider's `:timeout_ms` — registering a slow provider never widens anybody
  else's deadline. Exceptions, throws and exits are rescued and logged, and a
  provider process that dies some other way (killed from outside, or killed by
  an abnormal exit from something the provider linked to) is logged as a
  failure instead of reaching the caller. See `LemonMemory.Providers` for what
  that isolation does *not* cover.

  It is a safety net for the agent, not a licence for the provider: fan-out is
  synchronous, so a provider that blocks for its whole timeout on every query
  makes every memory search that slow, and a provider killed at its deadline
  gets no chance to clean up.

  ## Known gap: search has no error channel

  `c:search/2` returns `[Document.t()]` with no error branch, so "no results"
  and "my backend is unreachable" are the same answer and the platform cannot
  tell them apart or report degradation. Anything richer has to be added to
  this behaviour first; until then, providers should log their own failures.
  """

  alias LemonMemory.Document

  @typedoc """
  Which slice of memory a search covers.

  `:session` and `:agent` and `:workspace` are scoped by the matching
  `:scope_key`; `:all` is unscoped.
  """
  @type scope :: :session | :agent | :workspace | :all

  @typedoc """
  Options passed to `c:search/2`.

    * `:scope` — `t:scope/0`, defaults to `:session`
    * `:scope_key` — the session key, agent id or workspace key to scope to.
      When a scoped search arrives without one, return `[]` rather than
      widening the search to everything.
    * `:limit` — how many documents the caller wants. The registry re-trims
      after merging providers, so returning more is tolerated, not encouraged.
    * `:provider_id` — the id this provider was registered under, injected by
      `LemonMemory.Providers`.

  Providers must ignore keys they do not recognise.
  """
  @type search_opts :: keyword()

  @typedoc """
  Options passed to `c:put/2`. Carries `:provider_id`; otherwise provider-defined.
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

  @doc """
  Search this provider and return matching documents.

  Best-effort by contract: return `[]` for an empty result, an unparseable
  query, or an unreachable backend. Must not raise.
  """
  @callback search(query :: binary(), search_opts()) :: [Document.t()]
end
