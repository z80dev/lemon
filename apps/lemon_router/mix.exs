defmodule LemonRouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_router,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 69]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonRouter.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_ai, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:lemon_mcp, in_umbrella: true, runtime: false},
      {:lemon_memory, in_umbrella: true},
      {:lemon_media, in_umbrella: true},
      {:lemon_channels, in_umbrella: true},
      {:lemon_agent, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # RoutingFeedbackStore talks to SQLite directly; lemon_core only carries
      # :exqlite as an optional dep.
      {:exqlite, "~> 0.34.0"},
      # Property-based tests (StreamCoalescer byte-cap invariants).
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
