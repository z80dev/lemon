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

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:uuid, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.0"},
      {:exqlite, "~> 0.34.0"},
      {:file_system, "~> 1.0", optional: true},
      # Error reporting sink (see docs/error-reporting.md). Dormant unless
      # SENTRY_DSN is set at runtime. Finch is Sentry's default HTTP client
      # as of v12+, so it's an explicit (non-optional) dep here.
      {:sentry, "~> 13.0"},
      {:finch, "~> 0.21"}
    ]
  end
end
