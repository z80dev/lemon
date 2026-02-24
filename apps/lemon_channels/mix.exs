defmodule LemonChannels.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_channels,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonChannels.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:earmark_parser, "~> 1.4"},
      {:req, "~> 0.5.0"},
      {:nostrum, "~> 0.9", runtime: false}
    ]
  end
end
