defmodule LemonCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 44]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:term_ui, "~> 0.2.0"},
      {:exqlite, "~> 0.34.0"},
      {:yaml_elixir, "~> 2.9"},
      {:lemon_core, in_umbrella: true},
      {:ai, in_umbrella: true}
    ]
  end
end
