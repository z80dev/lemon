defmodule MarketIntel.MixProject do
  use Mix.Project

  def project do
    [
      app: :market_intel,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MarketIntel.Application, []}
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, "~> 0.12"},
      {:gen_stage, "~> 1.2"},
      # Internal deps
      {:lemon_core, in_umbrella: true},
      {:agent_core, in_umbrella: true},
      {:lemon_channels, in_umbrella: true, runtime: false}
    ]
  end
end
