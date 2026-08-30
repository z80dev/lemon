Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonBrowser.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_browser,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 60]],
      deps: deps(),
      name: "lemon_browser",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Browser capability driver for Lemon agents: a supervised local browser " <>
      "driver backed by a Node + Playwright helper process, navigation route " <>
      "classification and guardrails, and a metadata store for the artifacts " <>
      "a browser session leaves behind."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_browser),
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_browser/CHANGELOG.md"
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
      mod: {LemonBrowser.Application, []}
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
