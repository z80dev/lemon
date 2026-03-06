defmodule LemonMCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_mcp,
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
      mod: {LemonMCP.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.14"},
      # Umbrella dependencies
      {:coding_agent, in_umbrella: true},
      {:agent_core, in_umbrella: true}
    ]
  end
end
