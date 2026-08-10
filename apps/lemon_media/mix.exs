Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonMedia.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_media,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 72]],
      deps: deps(),
      name: "lemon_media",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Media job tracking for Lemon agents: a redacted metadata store for " <>
      "generated images, video, audio and transcriptions, with supervised " <>
      "job workers, lifecycle broadcasts and retention cleanup."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_media),
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_media/CHANGELOG.md"
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
      mod: {LemonMedia.Application, []}
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
