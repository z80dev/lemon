defmodule LemonEvals.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_evals,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 46]],
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
      {:agent_core, in_umbrella: true},
      {:ai, in_umbrella: true},
      {:coding_agent, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:lemon_skills, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
