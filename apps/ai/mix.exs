defmodule Ai.MixProject do
  use Mix.Project

  def project do
    [
      app: :ai,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 64]],
      deps: deps(),
      name: "Ai",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "Ai",
      source_url: "https://github.com/z80dev/lemon",
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Ai.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP client with streaming support
      {:req, "~> 0.5"},
      # JSON encoding/decoding
      {:jason, "~> 1.4"},
      # Options validation
      {:nimble_options, "~> 1.1"},
      # Required for Req.Test stubs
      {:plug, "~> 1.16", only: :test},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
