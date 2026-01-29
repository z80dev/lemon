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
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:req, "~> 0.5"},           # HTTP client with streaming support
      {:jason, "~> 1.4"},         # JSON encoding/decoding
      {:nimble_options, "~> 1.1"}, # Options validation
      {:plug, "~> 1.16", only: :test} # Required for Req.Test stubs
    ]
  end
end
