defmodule LemonCore.MixProject do
  use Mix.Project

  @version "0.3.0"
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
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 69]],
      deps: deps(),
      # LemonCore.ConfinedFS's descriptor-bound file helper (c_src/, Makefile)
      # lands in priv/. Inside the umbrella it is required: a missing make or
      # C compiler fails `mix compile`. As a Hex dependency it is built when
      # make and a C compiler are present; otherwise ConfinedFS reports
      # unavailable and its callers fail closed.
      compilers: helper_compilers(),
      make_env: %{"LEMON_CONFINED_FS_REQUIRED" => if(@umbrella, do: "1", else: "0")},
      make_clean: ["clean"],
      make_error_message:
        "lemon_core builds its file-confinement helper (c_src/lemon_confined_fs.c) " <>
          "with a C compiler and make; install them (Xcode Command Line Tools on " <>
          "macOS, build-essential on Debian/Ubuntu) and recompile.",
      name: "lemon_core",
      description: description(),
      package: package(),
      docs: docs()
    ] ++ umbrella_paths()
  end

  defp helper_compilers do
    if @umbrella or System.find_executable("make"),
      do: [:elixir_make] ++ Mix.compilers(),
      else: Mix.compilers()
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
      files: ~w(lib priv c_src Makefile mix.exs README.md CHANGELOG.md LICENSE),
      # Tooling for the lemon repository itself stays out of the tarball: the
      # architecture/docs lint (`mix lemon.quality`), benchmark runner and task
      # catalog. scripts/verify_packages compiles and runs the tarball without
      # those modules.
      exclude_patterns: [
        ~r{^lib/lemon_core/quality/},
        # The compiled helper is built per platform by the consumer.
        ~r{^priv/(lemon_confined_fs|\.lemon_confined_fs\.platform)},
        ~r{^lib/mix/tasks/lemon\.(quality|architecture\.docs|check_duplicate_tests|bench|help)\.ex$}
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

  # Only :jason, :toml, :telemetry, :mint and the build-time :elixir_make are
  # hard requirements. Everything else is optional so that a host application
  # can depend on lemon_core without inheriting a SQLite NIF, a pooled HTTP
  # client and a pubsub server it may not use. Each optional dep degrades
  # explicitly — see the module docs named below.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:telemetry, "~> 1.0"},
      # Builds the LemonCore.ConfinedFS helper (Makefile, c_src/).
      {:elixir_make, "~> 0.10", runtime: false},
      # LemonCore.Net.HTTP: the single pinned, unpooled outbound fetcher.
      {:mint, "~> 1.8"},
      # LemonCore.Bus falls back to a local Registry when absent.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      # Required by LemonCore.Store.SqliteBackend and RunHistoryStore; the ETS
      # backend needs none of them. (Durable memory moved to lemon_memory,
      # which depends on exqlite directly.)
      {:exqlite, "~> 0.43.0", optional: true},
      # LemonCore.ConfigReloader.Watcher polls when absent.
      {:file_system, "~> 1.0", optional: true},
      # Error reporting sink (see docs/error-reporting.md). Dormant unless
      # SENTRY_DSN is set at runtime; the handler is skipped when the modules
      # are missing. Finch is Sentry's HTTP client as of v12+.
      {:sentry, "~> 14.0", optional: true},
      {:finch, "~> 0.21", optional: true},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Property-based tests (Store round-trip/isolation, Events round-trip, UUID structure).
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
