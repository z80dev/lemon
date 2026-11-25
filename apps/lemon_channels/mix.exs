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
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 47]],
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      # Nostrum is an *included* application: its supervision tree runs under
      # LemonChannels.Adapters.Discord.Supervisor, so OTP only loads (never
      # starts) Nostrum's own dependencies. Nostrum opens its gateway and REST
      # connections with `:gun.open/3`, which needs gun's supervisor running,
      # so lemon_channels starts :gun itself (#670).
      extra_applications: [:logger, :gun],
      included_applications: [:nostrum],
      mod: {LemonChannels.Application, []}
    ]
  end

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      {:lemon_media, in_umbrella: true},
      {:lemon_agent, in_umbrella: true},
      {:lemon_ai, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:earmark_parser, "~> 1.4"},
      # LemonChannels.InboundHttp — the optional listener for adapters that
      # receive webhooks rather than polling. Off unless configured.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      # LemonChannels.Adapters.Email — message building and SMTP submission.
      {:gen_smtp, "~> 1.2"},
      {:mail, "~> 0.4"},
      {:req, "~> 0.6.0"},
      {:nostrum, "~> 0.9"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
