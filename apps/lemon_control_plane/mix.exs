defmodule LemonControlPlane.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_control_plane,
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
      mod: {LemonControlPlane.Application, []}
    ]
  end

  defp deps do
    [
      # Umbrella dependencies
      {:lemon_core, in_umbrella: true},
      {:lemon_router, in_umbrella: true},
      {:lemon_channels, in_umbrella: true},
      {:lemon_skills, in_umbrella: true},
      {:lemon_automation, in_umbrella: true},
      {:coding_agent, in_umbrella: true, runtime: false},
      {:ai, in_umbrella: true},
      # Games platform
      {:lemon_games, in_umbrella: true},
      # HTTP server
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      # JSON
      {:jason, "~> 1.4"}
    ]
  end
end
