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
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 47]],
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
      {:lemon_media, in_umbrella: true},
      {:agent_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:earmark_parser, "~> 1.4"},
      # LemonChannels.InboundHttp — the optional listener for adapters that
      # receive webhooks rather than polling. Off unless configured.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:nostrum, "~> 0.9", runtime: false}
    ]
  end
end
