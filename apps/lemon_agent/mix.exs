Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonAgent.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 71]],
      deps: deps(),
      name: "lemon_agent",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Agent runtime for the BEAM: the agentic loop with streaming events, " <>
      "supervised stateful agents, a tool registry, subagents, model routing " <>
      "and credentials, CLI engine runners, and workspace coordination stores."
  end

  # The OTP application stays :lemon_agent; the hex package is lemon_agent.
  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_agent),
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_agent/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LemonAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_ai, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
