defmodule LemonMemory.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_memory,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # Matches the coverage the moved suites already provide (60.17%). The
      # untested surface came along with the move: SessionSearch has no direct
      # test, and `mix lemon.memory` has none either.
      test_coverage: [summary: [threshold: 60]],
      deps: deps(),
      name: "LemonMemory",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "LemonMemory.Store",
      source_url: "https://github.com/z80dev/lemon",
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
    [
      {:lemon_core, in_umbrella: true},
      # Durable memory is SQLite-backed; unlike lemon_core, which only needs it
      # for optional subsystems, this app's whole reason to exist is the store.
      {:exqlite, "~> 0.34.0"},
      {:jason, "~> 1.4"},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
