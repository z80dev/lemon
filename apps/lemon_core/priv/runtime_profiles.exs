# Lemon runtime profiles: the single source of truth for which OTP
# applications a runtime starts.
#
# Read by the root mix.exs (`releases/0` builds `lemon_<profile>` from each
# entry) and at compile time by `LemonCore.Runtime.Profile`, which the source
# launcher (`LemonCore.Runtime.Boot`), `/healthz`, `lemon doctor` and
# `lemon setup runtime` use. Edit only this file to change what a runtime
# starts; `LemonCore.Runtime.ReleaseProfileTest` fails when the releases, the
# profiles or the deployment docs drift apart.
#
# Every entry is `{app, :permanent | :load}`, in start order:
#
#   * :permanent - started as a permanent application: when it exits, the
#     runtime stops instead of carrying on without it.
#   * :load - loaded, never started (a library without an application
#     callback).
#
# Which apps are named, and why:
#
#   * :exqlite, :sentry and :finch are optional deps of lemon_core, so nothing
#     starts them unless a runtime names them: the store's SQLite backend, the
#     error sink and the pooled HTTP client are part of a reference runtime.
#   * Satellites (:lemon_honcho, :lemon_computer_use) depend on the platform
#     and nothing depends on them; every registration they perform happens in
#     their `start/2`, so a runtime that does not name them silently never
#     starts them. An unconfigured satellite registers nothing.
#   * :lemon_automation and :lemon_skills are runtime dependencies of
#     lemon_control_plane and coding_agent, so every runtime starts them; they
#     are named so this list is the complete set the runtime starts.
#
# The two profiles differ only by the web UI: `runtime_min` is the headless
# runtime, `runtime_full` adds :lemon_web.
headless = [
  exqlite: :permanent,
  sentry: :permanent,
  finch: :permanent,
  lemon_browser: :permanent,
  lemon_media: :permanent,
  lemon_lsp: :permanent,
  lemon_omp: :permanent,
  lemon_computer_use: :permanent,
  lemon_skills: :permanent,
  coding_agent: :permanent,
  lemon_gateway: :permanent,
  lemon_cli: :permanent,
  lemon_router: :permanent,
  lemon_honcho: :permanent,
  lemon_channels: :permanent,
  lemon_automation: :permanent,
  lemon_control_plane: :permanent
]

[
  runtime_min: [
    description: "Headless runtime: the full agent runtime without the web UI.",
    applications: headless
  ],
  runtime_full: [
    description: "Full runtime: the headless runtime plus the web UI.",
    applications: headless ++ [lemon_web: :permanent]
  ]
]
