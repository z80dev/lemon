defmodule AgentCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 71]],
      deps: deps(),
      name: "AgentCore",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "AgentCore",
      source_url: "https://github.com/z80dev/lemon",
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AgentCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ai, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
