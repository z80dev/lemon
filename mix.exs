defmodule Lemon.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
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
      games_platform: [
        applications: [
          lemon_core: :permanent,
          lemon_games: :permanent,
          lemon_web: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
