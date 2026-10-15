# Changelog

All notable changes to `lemon_memory` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

### Added

- Exact-first, unique-substring note/project patching and deletion, with atomic
  ambiguity rejection and normal safety/capacity checks on patched results.
- Persistent backdoor and credential-exfiltration instruction screening, using
  the existing prompt-injection refusal reason.

## [0.2.0] - 2026-10-13

First release. `lemon_memory` is a new package, carved out of `lemon_core`,
where durable memory had been eight modules with no boundary of their own.

### Fixed

- Installable from Hex. The `0.1.0` release's `mix.exs` began with
  `Code.require_file("../../hex_package.exs", __DIR__)`, a file that was not in
  the package, so it failed to load in every consumer project; `0.1.0` is
  retired. The shipped `mix.exs` is now self-contained, and requires
  `lemon_core` as `~> 0.2`.

### Added

- Automatic local recall now carries agent-scoped, BM25-ranked conversation
  matches and the session workspace's USER.md facts in a bounded 2 KiB volatile
  block. It needs no model call; `[memory] auto_recall = false` disables it.
- `LemonMemory.Store.put_sync/1,2` for explicit review/confirm workflows that
  must know SQLite accepted a document before reporting success;
  create-if-absent `put_new_sync/1,2`, exact `get_document/1,2`, and exact
  `delete_document/1,2` prevent stale reviewers from overwriting rows and make
  their provenance-bearing records inspectable/removable. Also added
  `LemonMemory.Safety.redact/1` for a shared durable-boundary replacement pass.
- `LemonMemory.Doctor.Checks.Memory`, the `memory.session_search` doctor
  check, moved here from `lemon_core` (`LemonCore.Doctor.Checks.Memory`).
  Register it with `config :lemon_core, :doctor_checks, [LemonMemory.Doctor.Checks.Memory]`;
  it reads `LemonMemory.Store` directly instead of the `:doctor_runtime`
  `:memory_store` key. `LemonMemory.Store.database_path/0` returns the SQLite
  file the configured default store opens.

- `LemonMemory.Store` — SQLite-backed document store with full-text search over
  an agent's past work. Queries are sanitised before they reach FTS5, so agent-
  and human-authored queries containing quotes, wildcards or boolean operators
  return results instead of errors.
- `LemonMemory.Provider` — a behaviour for adding memory backends (a vector
  store, a wiki, an issue tracker). The contract is documented in prose in the
  moduledoc, including the parts that are easy to get wrong: `search/2` returns
  a bare list of documents, must not raise on user input, and must ignore
  options it does not recognise.
- `LemonMemory.Providers` — the fan-out registry. Every registered provider is
  queried in a task with a per-provider timeout, and exceptions and exits are
  rescued and logged, so one slow or broken provider degrades a search instead
  of failing it.
- `LemonMemory.Document` as the single record shape every provider reads and
  writes; `LemonMemory.Safety` for redaction and size limits before persistence;
  `LemonMemory.Query` for OR-joined lexical search terms; `LemonMemory.Recall`
  for bounded local conversation recall; and `LemonMemory.SessionSearch` for
  the scoped conversation search API.
- `LemonMemory.Document.new/1` builds a document from fields directly (for
  callers driving `LemonAgent` themselves), applying the same 2,000-byte summary
  truncation and required-field validation as `from_run/4`. Building the struct
  literally skips both, silently indexing whole transcripts;
  `LemonMemory.Document.max_summary_bytes/0` exposes the cap.
- `LemonMemory.Ingest` writes finished runs into memory by registering itself
  as a `LemonCore.Store` finalize-run hook, rather than being called by name
  from the store's hot path. It takes `:name` (default `LemonMemory.Ingest`)
  and reads `:memory_store`, `:config_loader` and `:config_ttl_ms` from
  `start_link/1` opts before `config :lemon_memory, LemonMemory.Ingest`, so an
  embedding application can run several isolated pipelines in one node: every
  public function takes the server as an optional first argument, and a
  non-default instance registers its hook as
  `{LemonMemory.Ingest, :handle_finalize_run, [name]}`. `:memory_store` accepts
  a registered store name as well as a pid or a module exporting `put/1`.
- `mix lemon.memory` for inspecting and searching the store from the shell.
- `LemonPlatformTest.ProviderCase` (in the `lemon_platform_test` package)
  verifies a provider against this contract.

### Changed

- Modules were renamed from `LemonCore.Memory*` to `LemonMemory.*`
  (`Document`, `Store`, `Provider`, `Providers`, `Providers.Local`, `Ingest`,
  `Safety`, `SessionSearch`, `TaskFingerprint`), and the application
  environment key moved from `:lemon_core, LemonCore.MemoryStore` to
  `:lemon_memory, LemonMemory.Store`. This was a clean break with no
  compatibility shims; `lemon_core` has no memory references left.
- `:exqlite` is a hard dependency here, not an optional one as in `lemon_core`.
  Supervision reflects that: `Providers` always starts, `Store` and `Ingest`
  start when SQLite is available.
- `Store.get_by_session/2`, `get_by_agent/2` and `get_by_workspace/2` now break
  `ingested_at_ms` ties by `doc_id`, so two documents written in the same
  millisecond come back in a stable order instead of an arbitrary one (a source
  of flaky ordering assertions).

### Known gaps

- `Provider.search/2` has no error channel, so "no results" and "my backend is
  unreachable" are indistinguishable to the platform. Widening it is a
  behaviour change and is deliberately deferred.
