defmodule LemonWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 5]],
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      mod: {LemonWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:lemon_agent, in_umbrella: true},
      {:lemon_automation, in_umbrella: true},
      {:lemon_control_plane, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:lemon_memory, in_umbrella: true},
      {:lemon_router, in_umbrella: true},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:earmark_parser, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  # Tailwind source lives in assets/; the built priv/static/assets/app.css is
  # committed so releases need no Node toolchain. From the umbrella root:
  # `mix do --app lemon_web assets.setup` once, then `mix do --app lemon_web assets.build`.
  defp aliases do
    [
      "assets.setup": ["cmd --cd assets npm ci --cache /tmp/lemon-web-npm-cache"],
      "assets.build": ["cmd --cd assets npm run build"]
    ]
  end
end
