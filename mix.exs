defmodule Lemon.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2026.05.0",
      start_permanent: Mix.env() == :prod,
      # Coverage thresholds are enforced per app; see each app's mix.exs.
      deps: deps(),
      releases: releases()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    []
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
