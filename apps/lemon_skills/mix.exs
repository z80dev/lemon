Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonSkills.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_skills,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 64]],
      deps: deps(),
      name: "lemon_skills",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Skills for Lemon agents: a registry of file-based SKILL.md bundles with " <>
      "discovery from disk, git and MCP sources, trust levels, audited " <>
      "installation, and the assistant tools that read them back."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_skills),
      licenses: ["MIT"],
      # priv/ ships the built-in skills the application seeds on first start.
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_skills/CHANGELOG.md"
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
      extra_applications: [:logger],
      mod: {LemonSkills.Application, []}
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_core, in_umbrella: true},
      {:lemon_memory, in_umbrella: true},
      {:lemon_media, in_umbrella: true},
      {:lemon_agent, in_umbrella: true},
      {:lemon_ai, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:phoenix_pubsub, "~> 2.1"},
      {:req, "~> 0.5"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
