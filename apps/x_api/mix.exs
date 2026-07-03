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
      {:jason, "~> 1.4"},
      {:req, "~> 0.5.0"}
    ]
  end
end
