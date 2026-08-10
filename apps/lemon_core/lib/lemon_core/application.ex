defmodule LemonCore.Application do
  @moduledoc """
  Application supervisor for the LemonCore OTP application.

  This module is the entry point for the lemon_core application. It starts
  the supervision tree with the following children:

  - The `LemonCore.Bus` backend - Phoenix.PubSub, or a Registry when
    `phoenix_pubsub` is not available
  - LemonCore.ConfigCache - Configuration caching service
  - LemonCore.Store - Key-value storage backend
  - LemonCore.MemoryStore - Durable memory document store (separate SQLite DB)
  - LemonCore.MemoryProviders - Memory-provider registry and fan-out boundary
  - LemonCore.MemoryIngest - Async run ingest pipeline for memory documents
  - LemonCore.ConfigReloader - Runtime config reload orchestrator
  - LemonCore.ConfigReloader.Watcher - File-system watcher for config changes
  - LemonCore.ProviderPoolRotator - In-memory provider pool rotation state

  The supervisor uses a :one_for_one strategy, meaning if a child process
  crashes, only that process will be restarted.

  `LemonCore.RunHistoryStore`, `LemonCore.MemoryStore` and
  `LemonCore.MemoryIngest` are only started when the optional `:exqlite`
  dependency is present.

  ## Configuration

  The application reads configuration from the application environment:

  - `:lemon_core, LemonCore.ConfigCache` - Options passed to ConfigCache
  - `:lemon_core, :logging` - File logging configuration (optional)
  - `:lemon_core, :logger` - `:logger` handlers to attach at boot (e.g. the
    Sentry error-reporting handler; see `docs/error-reporting.md`). Empty
    unless `SENTRY_DSN` is set at runtime, in which case this is a no-op.

  ## Examples

      # Starting the application
      Application.ensure_all_started(:lemon_core)

      # Accessing the supervisor
      Process.whereis(LemonCore.Supervisor)
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Attach any :logger handlers configured under :lemon_core, :logger (see
    # config/runtime.exs). A no-op when nothing is configured there.
    drop_unloadable_handlers()
    Logger.add_handlers(:lemon_core)

    # If configured, install a log-to-file handler early so dropped/errored
    # messages can be diagnosed even when stdout/stderr isn't persisted.
    _ = LemonCore.Logging.maybe_add_file_handler()

    config_cache_opts = Application.get_env(:lemon_core, LemonCore.ConfigCache, [])

    children =
      [
        LemonCore.Bus.child_spec_for_backend(),
        {LemonCore.ConfigCache, config_cache_opts},
        LemonCore.Store
      ] ++
        sqlite_children() ++
        [
          LemonCore.MemoryProviders,
          LemonCore.ConfigReloader,
          LemonCore.ConfigReloader.Watcher,
          LemonCore.ProviderPoolRotator
        ]

    opts = [strategy: :one_for_one, name: LemonCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # RunHistoryStore, MemoryStore and the ingest pipeline that feeds it all need
  # the SQLite NIF. `:exqlite` is an optional dependency, so without it the rest
  # of lemon_core still boots: run history reads exit with `:noproc` and ingest
  # casts are dropped.
  defp sqlite_children do
    if Code.ensure_loaded?(Exqlite.Sqlite3) do
      [LemonCore.RunHistoryStore, LemonCore.MemoryStore, LemonCore.MemoryIngest]
    else
      Logger.info(
        "exqlite is not available: run history and durable memory are disabled. " <>
          "Add {:exqlite, \"~> 0.34\"} to your deps to enable them."
      )

      []
    end
  end

  # `:logger` handlers are configured by name (the Sentry handler is only
  # configured when SENTRY_DSN is set). Skip any whose module is missing —
  # sentry is optional, and an unloadable handler module takes the boot down.
  defp drop_unloadable_handlers do
    configured = Application.get_env(:lemon_core, :logger, [])

    {loadable, missing} =
      Enum.split_with(configured, fn
        {:handler, _id, module, _config} -> Code.ensure_loaded?(module)
        _other -> true
      end)

    for {:handler, id, module, _config} <- missing do
      Logger.warning(
        "Skipping :logger handler #{inspect(id)}: #{inspect(module)} is not available. " <>
          "Add the dependency that provides it to enable this handler."
      )
    end

    if missing != [] do
      Application.put_env(:lemon_core, :logger, loadable)
    end

    :ok
  end
end
