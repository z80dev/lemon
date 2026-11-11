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
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [summary: [threshold: 61]],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:idna, "~> 7.1"},
      {:mint, "~> 1.8"},
      # Local HTTP/SSE MCP server fixtures for the client tests
      {:bandit, "~> 1.0", only: :test},
      {:plug, "~> 1.14", only: :test},
      # Umbrella dependencies
      {:lemon_core, in_umbrella: true},
      {:lemon_skills, in_umbrella: true}
    ]
  end
end
