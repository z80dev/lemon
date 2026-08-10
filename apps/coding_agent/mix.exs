defmodule CodingAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 67]],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CodingAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:agent_core, in_umbrella: true},
      {:ai, in_umbrella: true},
      {:lemon_skills, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:lemon_gateway, in_umbrella: true},
      {:lemon_memory, in_umbrella: true},
      {:lemon_browser, in_umbrella: true},
      # Test-only: CodingAgent.GatewayEngine is an out-of-app LemonGateway.Engine,
      # so it is held to the same contract kit third-party engines use.
      {:lemon_platform_test, in_umbrella: true, only: :test, runtime: false},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:readability, "~> 0.12"},
      {:httpoison, "~> 3.0", override: true}
    ]
  end
end
