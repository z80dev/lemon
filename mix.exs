defmodule Lemon.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2026.08.1",
      start_permanent: Mix.env() == :prod,
      # Coverage thresholds are enforced per app; see each app's mix.exs.
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    [
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "sim_ui.assets.setup": [
        "do --app lemon_sim_ui cmd --cd assets npm ci --cache /tmp/lemon-sim-ui-npm-cache"
      ],
      "sim_ui.assets.build": ["do --app lemon_sim_ui cmd --cd assets npm run build"],
      "sim_ui.assets.audit": [
        "do --app lemon_sim_ui cmd --cd assets npm audit --audit-level=high --cache /tmp/lemon-sim-ui-npm-cache"
      ],
      "sim_ui.assets.deploy": [
        "sim_ui.assets.setup",
        "sim_ui.assets.audit",
        "sim_ui.assets.build",
        "do --app lemon_sim_ui phx.digest"
      ]
    ]
  end

  # Advisory Dialyzer lane (see .github/workflows/dialyzer.yml). PLTs are
  # written under _build/ so they're picked up by the existing gitignore
  # rule and can be cached in CI keyed on mix.lock.
  defp dialyzer do
    [
      plt_core_path: "_build/dialyzer",
      plt_local_path: "_build/dialyzer",
      # :nostrum is runtime: false in lemon_channels, so dialyxir's automatic
      # per-app PLT discovery never pulls it in on its own; add it explicitly
      # so Discord adapter calls into Nostrum.Api.* type-check.
      plt_add_apps: [:mix, :ex_unit, :public_key, :nostrum],
      flags: [:error_handling, :unmatched_returns],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  # Release configuration for games.zeebot.xyz
  #
  # lemon_core carries :exqlite, :sentry and :finch as optional deps (see
  # apps/lemon_core/mix.exs), so the runtime releases name them explicitly:
  # prod configures the SQLite store backend, and the error sink is part of
  # what "reference runtime" means here.
  #
  # The :lemon_honcho satellite must be named here too, for the opposite
  # reason: it depends on the platform and nothing in the platform depends on
  # it, so a release that does not list it simply never starts it — and every
  # registration a satellite performs happens in its `start/2`. The omission is
  # silent, which is why it is listed in both runtimes rather than only in
  # the full one; an unconfigured satellite registers nothing and costs nothing.
  #
  # lemon_mcp is different again: it is a library with no application callback.
  # Both runtimes load it explicitly so LemonSkills.McpSource can discover the
  # client modules dynamically, while callers remain responsible for supervising
  # every MCP client, server, and transport process they start.
  defp releases do
    [
      lemon_runtime_min: [
        applications: [
          exqlite: :permanent,
          sentry: :permanent,
          finch: :permanent,
          lemon_core: :permanent,
          lemon_browser: :permanent,
          lemon_media: :permanent,
          lemon_lsp: :permanent,
          lemon_mcp: :load,
          coding_agent: :permanent,
          lemon_gateway: :permanent,
          lemon_cli: :permanent,
          lemon_router: :permanent,
          lemon_honcho: :permanent,
          lemon_channels: :permanent,
          lemon_control_plane: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ],
      lemon_runtime_full: [
        applications: [
          exqlite: :permanent,
          sentry: :permanent,
          finch: :permanent,
          lemon_core: :permanent,
          lemon_browser: :permanent,
          lemon_media: :permanent,
          lemon_lsp: :permanent,
          lemon_mcp: :load,
          coding_agent: :permanent,
          lemon_gateway: :permanent,
          lemon_cli: :permanent,
          lemon_router: :permanent,
          lemon_honcho: :permanent,
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
          exqlite: :permanent,
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
