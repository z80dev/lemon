defmodule LemonSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_sim,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonSim.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      {:agent_core, in_umbrella: true},
      {:ai, in_umbrella: true}
    ]
  end
end
