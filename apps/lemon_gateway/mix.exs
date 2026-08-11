Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonGateway.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_gateway,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 46]],
      deps: deps(),
      name: "lemon_gateway",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Engine execution runtime for Lemon agents: the Engine behaviour, engine " <>
      "registry and scheduler, per-conversation launch locks and session " <>
      "resumption, plus the HTTP and SMS ingress surfaces that are not channels."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_gateway),
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      # `files` globs the working tree, not the index, so anything gitignored
      # that happens to exist locally would otherwise ship. priv/.env is a
      # documented local path for this app.
      exclude_patterns: [~r/\.env/, ~r/node_modules/],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_gateway/CHANGELOG.md"
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {LemonGateway.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    Lemon.HexPackage.deps([
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      # HTTP webhook listener (Twilio SMS inbox utility)
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      # Markdown -> Telegram rendering uses entities (no parse_mode) for robust formatting.
      {:earmark_parser, "~> 1.4"},
      # WebSocket support
      {:websockex, "~> 0.4"},
      {:websock_adapter, "~> 0.5"},
      {:lemon_agent, in_umbrella: true},
      {:lemon_cli_runners, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end
