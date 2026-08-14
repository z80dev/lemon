Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonMemory.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_memory,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      # Floor, not a target: `SessionSearch` now has a direct suite, but
      # `mix lemon.memory` is still untested, so the threshold stays where the
      # moved suites put it rather than tracking each gain.
      test_coverage: [summary: [threshold: 60]],
      deps: deps(),
      name: "lemon_memory",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Durable memory for agents: document schema, SQLite-backed full-text " <>
      "store, a provider behaviour with isolated fan-out search, run ingest, " <>
      "redaction and task fingerprints."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_memory),
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_memory/CHANGELOG.md"
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
      mod: {LemonMemory.Application, []}
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_core, in_umbrella: true},
      # Durable memory is SQLite-backed; unlike lemon_core, which only needs it
      # for optional subsystems, this app's whole reason to exist is the store.
      {:exqlite, "~> 0.34.0"},
      {:jason, "~> 1.4"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
