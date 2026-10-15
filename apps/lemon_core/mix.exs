defmodule LemonCore.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/z80dev/lemon"

  # This file ships verbatim in the hex tarball, so it must not read anything
  # outside its own directory. Inside the lemon repo it sits at
  # apps/lemon_core/mix.exs under the umbrella's mix.exs and shares the
  # umbrella's build, deps and lockfile; anywhere else (deps/lemon_core in a
  # consumer, an unpacked tarball) it is a standalone package.
  # LEMON_HEX_PUBLISH=1 forces the standalone form inside the repo.
  @umbrella Path.basename(Path.dirname(__DIR__)) == "apps" and
              File.regular?(Path.expand("../../mix.exs", __DIR__)) and
              System.get_env("LEMON_HEX_PUBLISH") not in ["1", "true"]

  def project do
    [
      app: :lemon_core,
      version: @version,
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 69]],
      deps: deps(),
      name: "lemon_core",
      description: description(),
      package: package(),
      docs: docs()
    ] ++ umbrella_paths()
  end

  defp umbrella_paths do
    if @umbrella do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end

  defp description do
    "The shared language of the Lemon agent platform: event bus, pluggable " <>
      "store, encrypted secrets, config loading, filesystem layout, and the " <>
      "boundary contracts every other Lemon package speaks."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE),
      # Tooling for the lemon repository itself stays out of the tarball: the
      # architecture/docs lint (`mix lemon.quality`), the managed-install
      # self-updater (`mix lemon.update`), the repo's benchmark runner and task
      # catalog. Nothing else in lib/ references these modules, and
      # scripts/verify_packages compiles the tarball without them.
      exclude_patterns: [
        ~r{^lib/lemon_core/(quality|update)/},
        ~r{^lib/mix/tasks/lemon\.(quality|architecture\.docs|check_duplicate_tests|update|bench|help)\.ex$}
      ],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_core/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  def application do
    [
      # :inets and :ssl back LemonCore.Httpc. They must be declared, not just
      # started at runtime: Mix prunes undeclared OTP applications from the code
      # path, which leaves httpc half-loaded (`:http_util` undefined).
      extra_applications: [:logger, :public_key, :inets, :ssl],
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
      # Required by LemonCore.Store.SqliteBackend and RunHistoryStore; the ETS
      # backend needs none of them. (Durable memory moved to lemon_memory,
      # which depends on exqlite directly.)
      {:exqlite, "~> 0.34.0", optional: true},
      # LemonCore.ConfigReloader.Watcher polls when absent.
      {:file_system, "~> 1.0", optional: true},
      # Error reporting sink (see docs/error-reporting.md). Dormant unless
      # SENTRY_DSN is set at runtime; the handler is skipped when the modules
      # are missing. Finch is Sentry's HTTP client as of v12+.
      {:sentry, "~> 13.0", optional: true},
      {:finch, "~> 0.21", optional: true},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Property-based tests (Store round-trip/isolation, Events round-trip, UUID structure).
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
