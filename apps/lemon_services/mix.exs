defmodule LemonServices.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_services,
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
      mod: {LemonServices.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"}
    ]
  end
end
