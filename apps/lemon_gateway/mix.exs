defmodule LemonGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_gateway,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {LemonGateway.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"},
      {:toml, "~> 0.7"},
      # HTTP webhook listener (Twilio SMS inbox utility)
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:gen_smtp, "~> 1.2"},
      {:mail, "~> 0.4"},
      # Markdown -> Telegram rendering uses entities (no parse_mode) for robust formatting.
      {:earmark_parser, "~> 1.4"},
      # WebSocket support
      {:websockex, "~> 0.4"},
      {:websock_adapter, "~> 0.5"},
      {:agent_core, in_umbrella: true},
      {:coding_agent, in_umbrella: true},
      {:lemon_channels, in_umbrella: true, runtime: false},
      {:lemon_core, in_umbrella: true}
    ]
  end
end
