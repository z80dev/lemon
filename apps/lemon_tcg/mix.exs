defmodule LemonTcg.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_tcg,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 40]],
      deps: deps(),
      name: "LemonTcg",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "LemonTcg",
      source_url: "https://github.com/z80dev/lemon",
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonTcg.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      {:agent_core, in_umbrella: true},
      {:ai, in_umbrella: true},
      # Kernel runner + deciders for the live agent loop
      {:lemon_sim, in_umbrella: true},
      # HTTP client for marketplace and price APIs
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # Required for Req.Test stubs
      {:plug, "~> 1.16", only: :test},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
