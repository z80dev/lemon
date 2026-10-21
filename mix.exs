defmodule Lemon.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2026.10.18",
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
      "sim_ui.assets.deploy": [
        "sim_ui.assets.setup",
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
  # every MCP client and transport process they start.
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
          lemon_omp: :permanent,
          lemon_computer_use: :permanent,
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
        steps: [:assemble, &bundle_browser_driver/1, &stamp_build/1, :tar]
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
          lemon_omp: :permanent,
          lemon_computer_use: :permanent,
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
        steps: [:assemble, &bundle_browser_driver/1, &stamp_build/1, :tar]
      ],
      sim_broadcast_platform: [
        applications: [
          exqlite: :permanent,
          lemon_core: :permanent,
          lemon_sim: :permanent,
          lemon_sim_ui: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, &stamp_build/1, :tar]
      ]
    ]
  end

  defp stamp_build(release) do
    commit =
      System.get_env("LEMON_GIT_SHA") ||
        case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha)
          _ -> "unknown"
        end

    metadata = %{
      version: release.version,
      commit: commit,
      channel: System.get_env("LEMON_CHANNEL") || "stable"
    }

    File.write!(Path.join(release.version_path, "lemon-build.json"), Jason.encode!(metadata))
    release
  end

  # Runtime releases ship the local browser driver so a packaged install needs
  # only Node.js and Chrome, never a source checkout. The driver is rebuilt from
  # the lockfile on every release (a stale dist/ must not ship), and only its
  # production dependencies are staged under lemon_browser's priv/driver, where
  # LemonBrowser.LocalServer resolves it.
  defp bundle_browser_driver(release) do
    client = Path.expand("clients/lemon-browser-node", __DIR__)
    vsn = release.applications |> Map.fetch!(:lemon_browser) |> Keyword.fetch!(:vsn)
    target = Path.join([release.path, "lib", "lemon_browser-#{vsn}", "priv", "driver"])

    npm!(client, ["ci", "--no-audit", "--no-fund"])
    npm!(client, ["run", "build"])

    File.rm_rf!(target)
    File.mkdir_p!(target)
    File.cp_r!(Path.join(client, "dist"), target)

    for file <- ~w(package.json package-lock.json) do
      File.cp!(Path.join(client, file), Path.join(target, file))
    end

    npm!(target, ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"])
    release
  end

  defp npm!(dir, args) do
    npm =
      System.find_executable("npm") || Mix.raise("npm is required to bundle the browser driver")

    case System.cmd(npm, args, cd: dir, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("npm #{Enum.join(args, " ")} failed in #{dir} (exit #{status})")
    end
  end
end
