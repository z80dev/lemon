defmodule LemonCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key],
      mod: {LemonCore.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:term_ui, "~> 0.2.0"},
      {:uuid, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.0"},
      {:exqlite, "~> 0.34.0"},
      {:file_system, "~> 1.0", optional: true}
    ]
  end
end
