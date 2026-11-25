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
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 44]],
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {LemonCli.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:exqlite, "~> 0.43.0"},
      {:yaml_elixir, "~> 2.9"},
      {:lemon_core, in_umbrella: true},
      # Library only: passive browser selection and the local pane client.
      {:lemon_browser, in_umbrella: true, runtime: false},
      {:lemon_agent, in_umbrella: true},
      {:lemon_control_plane, in_umbrella: true, only: :test, runtime: false},
      {:lemon_memory, in_umbrella: true},
      {:lemon_skills, in_umbrella: true},
      {:lemon_ai, in_umbrella: true}
    ]
  end
end
