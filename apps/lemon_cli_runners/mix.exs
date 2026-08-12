Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonCliRunners.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_cli_runners,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      # Matches the coverage the moved suites already provide (69.35% at
      # extraction from lemon_agent).
      test_coverage: [summary: [threshold: 69]],
      deps: deps(),
      name: "lemon_cli_runners",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Vendor AI CLIs (Claude Code, Codex, Kimi, OpenCode, Pi) wrapped " <>
      "as streaming subagents: JSONL subprocess management, per-vendor event " <>
      "schemas, session resume, and lifecycle control."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_cli_runners),
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_cli_runners/CHANGELOG.md"
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

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_agent, in_umbrella: true},
      {:lemon_ai, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
