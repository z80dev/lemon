defmodule XApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :x_api,
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
      mod: {XApi.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      # The channel adapter implements LemonChannels.Plugin and the three agent
      # tools implement the LemonAgent tool contract. Satellite -> platform is
      # the allowed direction; the platform never depends on this app.
      {:lemon_channels, in_umbrella: true},
      {:lemon_agent, in_umbrella: true},
      {:lemon_ai, in_umbrella: true},
      # The satellite proves its adapter against the published contract kit the
      # same way any third-party integration would.
      {:lemon_platform_test, in_umbrella: true, only: :test, runtime: false},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"}
    ]
  end
end
