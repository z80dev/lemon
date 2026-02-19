defmodule LemonPoker.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_poker,
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
      mod: {LemonPoker.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      {:lemon_router, in_umbrella: true},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.18"},
      {:websock_adapter, "~> 0.5"},
      {:req, "~> 0.5"},
      {:floki, "~> 0.36"}
    ]
  end
end
