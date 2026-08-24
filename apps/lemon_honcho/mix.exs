defmodule LemonHoncho.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_honcho,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 35]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonHoncho.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      # The satellite implements three platform contracts: a
      # `LemonMemory.Provider`, a `LemonAgent.ContextRegistry` contributor, and
      # a handful of agent tools. Satellite -> platform is the allowed
      # direction; nothing in the platform names this app.
      {:lemon_memory, in_umbrella: true},
      {:lemon_agent, in_umbrella: true},
      {:lemon_ai, in_umbrella: true},
      # The satellite proves its provider against the published contract kit
      # the same way any third-party integration would.
      {:lemon_platform_test, in_umbrella: true, only: :test, runtime: false},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # Required for Req.Test stubs, which is how the HTTP client is tested.
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
