Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonChannels.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

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
      test_coverage: [summary: [threshold: 47]],
      deps: deps(),
      name: "lemon_channels",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Messaging channels for BEAM agents: the Plugin behaviour, adapter " <>
      "registry, delivery dispatcher, retrying outbox and presentation state, " <>
      "with Telegram, Discord, WhatsApp, XMTP and email adapters built in."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_channels),
      licenses: ["MIT"],
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE),
      # `files` globs the working tree, not the index, so anything gitignored
      # that happens to exist locally (a bridge's node_modules, a stray .env)
      # would otherwise ship.
      exclude_patterns: [~r/\.env/, ~r/node_modules/],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_channels/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonChannels.Application, []}
    ]
  end

  defp deps do
    Lemon.HexPackage.deps([
      {:lemon_core, in_umbrella: true},
      {:lemon_media, in_umbrella: true},
      {:agent_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:earmark_parser, "~> 1.4"},
      # LemonChannels.InboundHttp — the optional listener for adapters that
      # receive webhooks rather than polling. Off unless configured.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      # LemonChannels.Adapters.Email — message building and SMTP submission.
      {:gen_smtp, "~> 1.2"},
      {:mail, "~> 0.4"},
      {:req, "~> 0.5"},
      {:nostrum, "~> 0.9", runtime: false},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
