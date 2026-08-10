defmodule LemonCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 69]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key],
      mod: {LemonCore.Application, []}
    ]
  end

  # Only :jason, :toml and :telemetry are hard requirements. Everything else is
  # optional so that a host application can depend on lemon_core without
  # inheriting a SQLite NIF, an HTTP client and a pubsub server it may not use.
  # Each optional dep degrades explicitly — see the module docs named below.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:telemetry, "~> 1.0"},
      # LemonCore.Bus falls back to a local Registry when absent.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      # Required by LemonCore.Store.SqliteBackend, MemoryStore and
      # RunHistoryStore; the ETS backend needs none of them.
      {:exqlite, "~> 0.34.0", optional: true},
      # LemonCore.ConfigReloader.Watcher polls when absent.
      {:file_system, "~> 1.0", optional: true},
      # Error reporting sink (see docs/error-reporting.md). Dormant unless
      # SENTRY_DSN is set at runtime; the handler is skipped when the modules
      # are missing. Finch is Sentry's HTTP client as of v12+.
      {:sentry, "~> 13.0", optional: true},
      {:finch, "~> 0.21", optional: true}
    ]
  end
end
