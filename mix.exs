defmodule Lemon.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2026.05.0",
      start_permanent: Mix.env() == :prod,
      # Coverage thresholds are enforced per app; see each app's mix.exs.
      deps: deps(),
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Advisory Dialyzer lane (see .github/workflows/dialyzer.yml). PLTs are
  # written under _build/ so they're picked up by the existing gitignore
  # rule and can be cached in CI keyed on mix.lock.
  defp dialyzer do
    [
      plt_core_path: "_build/dialyzer",
      plt_local_path: "_build/dialyzer",
      plt_add_apps: [:mix, :ex_unit, :public_key],
      flags: [:error_handling, :unmatched_returns],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  # Release configuration for games.zeebot.xyz
  defp releases do
    [
      lemon_runtime_min: [
        applications: [
          lemon_core: :permanent,
          lemon_browser: :permanent,
          lemon_media: :permanent,
          lemon_lsp: :permanent,
          coding_agent: :permanent,
          lemon_gateway: :permanent,
          lemon_router: :permanent,
          x_api: :permanent,
          lemon_channels: :permanent,
          lemon_control_plane: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ],
      lemon_runtime_full: [
        applications: [
          lemon_core: :permanent,
          lemon_browser: :permanent,
          lemon_media: :permanent,
          lemon_lsp: :permanent,
          coding_agent: :permanent,
          lemon_gateway: :permanent,
          lemon_router: :permanent,
          x_api: :permanent,
          lemon_channels: :permanent,
          lemon_control_plane: :permanent,
          lemon_automation: :permanent,
          lemon_skills: :permanent,
          lemon_web: :permanent,
          lemon_sim_ui: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ],
      sim_broadcast_platform: [
        applications: [
          lemon_core: :permanent,
          lemon_sim: :permanent,
          lemon_sim_ui: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
