defmodule LemonIngestion.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_ingestion,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonIngestion.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:lemon_core, in_umbrella: true},
      {:lemon_router, in_umbrella: true},
      {:lemon_gateway, in_umbrella: true}
    ]
  end
end
