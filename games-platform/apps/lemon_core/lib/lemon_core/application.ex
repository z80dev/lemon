defmodule LemonCore.Application do
  @moduledoc """
  Application supervisor for the LemonCore OTP application.

  This module is the entry point for the lemon_core application. It starts
  the supervision tree with the following children:

  - Phoenix.PubSub - PubSub for inter-process communication
  - LemonCore.ConfigCache - Configuration caching service
  - LemonCore.Store - Key-value storage backend
  - LemonCore.ConfigReloader - Runtime config reload orchestrator
  - LemonCore.ConfigReloader.Watcher - File-system watcher for config changes
  - LemonCore.Browser.LocalServer - Local browser automation server

  The supervisor uses a :one_for_one strategy, meaning if a child process
  crashes, only that process will be restarted.

  ## Configuration

  The application reads configuration from the application environment:

  - `:lemon_core, LemonCore.ConfigCache` - Options passed to ConfigCache
  - `:lemon_core, :logging` - File logging configuration (optional)

  ## Examples

      # Starting the application
      Application.ensure_all_started(:lemon_core)

      # Accessing the supervisor
      Process.whereis(LemonCore.Supervisor)
  """

  use Application

  @impl true
  def start(_type, _args) do
    # If configured, install a log-to-file handler early so dropped/errored
    # messages can be diagnosed even when stdout/stderr isn't persisted.
    _ = LemonCore.Logging.maybe_add_file_handler()

    config_cache_opts = Application.get_env(:lemon_core, LemonCore.ConfigCache, [])

    children = [
      {Phoenix.PubSub, name: LemonCore.PubSub},
      {LemonCore.ConfigCache, config_cache_opts},
      LemonCore.Store,
      LemonCore.ConfigReloader,
      LemonCore.ConfigReloader.Watcher,
      LemonCore.Browser.LocalServer
    ]

    opts = [strategy: :one_for_one, name: LemonCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
