Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonRouter.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

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
      deps: deps(),
      name: "lemon_router",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Run lifecycle and session orchestration for Lemon agents: single-flight " <>
      "execution per conversation, queueing and steering, coalescing, policy, " <>
      "watchdog and delivery routing."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_router),
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_router/CHANGELOG.md"
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
      extra_applications: [:logger],
      mod: {LemonRouter.Application, []}
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_ai, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:lemon_memory, in_umbrella: true},
      {:lemon_media, in_umbrella: true},
      {:lemon_channels, in_umbrella: true},
      {:lemon_agent, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      # RoutingFeedbackStore talks to SQLite directly; lemon_core only carries
      # :exqlite as an optional dep.
      {:exqlite, "~> 0.34.0"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Property-based tests (StreamCoalescer byte-cap invariants).
      {:stream_data, "~> 1.1", only: :test}
    ])
  end
end
