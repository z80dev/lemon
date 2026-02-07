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
      {:lemon_core, in_umbrella: true},
      {:lemon_gateway, in_umbrella: true},
      {:lemon_channels, in_umbrella: true},
      {:coding_agent, in_umbrella: true},
      {:agent_core, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
