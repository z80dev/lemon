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
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  defp releases do
    [
      games_platform: [
        applications: [
          lemon_core: :permanent,
          lemon_games: :permanent,
          lemon_web: :permanent
        ],
        include_executables_for: [:unix],
        cookie: "games_platform_cookie"
      ]
    ]
  end
end
