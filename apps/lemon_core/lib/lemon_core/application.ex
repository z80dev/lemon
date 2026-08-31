defmodule LemonCore.Application do
  @moduledoc """
  Application supervisor for the LemonCore OTP application.

  This module is the entry point for the lemon_core application. It starts
  the supervision tree with the following children:

  - The `LemonCore.Bus` backend - Phoenix.PubSub, or a Registry when
    `phoenix_pubsub` is not available
  - `LemonCore.ACPClientBridge` - Registry for direct ACP client request/reply
  - `LemonCore.NodeRegistry` - Live named execution-node registry and invocation broker
  - LemonCore.ConfigCache - Configuration caching service
  - LemonCore.Store - Key-value storage backend
  - `LemonCore.Secrets.SourceTaskSupervisor` - Bounded external-source tasks
  - `LemonCore.Secrets.SourceCache` - Bounded optional process-local source cache
  - LemonCore.RunHistoryStore - Per-session run history (separate SQLite DB)
  - LemonCore.ConfigReloader - Runtime config reload orchestrator
  - LemonCore.ConfigReloader.Watcher - File-system watcher for config changes

  The supervisor uses a :one_for_one strategy, meaning if a child process
  crashes, only that process will be restarted.

  `LemonCore.RunHistoryStore` is only started when the optional `:exqlite`
  dependency is present. Durable memory lives in the `lemon_memory` app and
  supervises itself.

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
        LemonCore.ACPClientBridge,
        LemonCore.NodeRegistry,
        {LemonCore.ConfigCache, config_cache_opts},
        LemonCore.Store,
        {Task.Supervisor, name: LemonCore.Secrets.SourceTaskSupervisor},
        LemonCore.Secrets.SourceCache
      ] ++
        sqlite_children() ++
        [
          LemonCore.ConfigReloader,
          LemonCore.ConfigReloader.Watcher
        ]

    opts = [strategy: :one_for_one, name: LemonCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # RunHistoryStore needs the SQLite NIF. `:exqlite` is an optional dependency,
  # so without it the rest of lemon_core still boots and run history reads exit
  # with `:noproc`.
  defp sqlite_children do
    if Code.ensure_loaded?(Exqlite.Sqlite3) do
      [LemonCore.RunHistoryStore]
    else
      Logger.warning(
        "exqlite is not available, so LemonCore.RunHistoryStore was not started: " <>
          "run history is silently disabled (reads return empty and finalize-run " <>
          "hooks that persist history do nothing). Durable memory has the same " <>
          "requirement in lemon_memory. :exqlite is an optional dependency of " <>
          "lemon_core, so declare it yourself to enable these: " <>
          "{:exqlite, \"~> 0.34\"}."
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
