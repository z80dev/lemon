# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "secret", "token", "hosted_werewolf_", "params"]

config :logger, :default_formatter,
  metadata: [
    :session_id,
    :original_message_count,
    :restored_message_count,
    :violations,
    :sim_id,
    :turn
  ]

# Lane concurrency caps for CodingAgent.LaneQueue
# Keep main cap at 4 to stay within Telegram's per-chat rate limits.
# Subagent and background_exec can be higher since they don't all
# route through the same Telegram chat.
config :coding_agent, :lane_caps,
  main: 8,
  subagent: 16,
  background_exec: 8

config :coding_agent, :async_followups, default_queue_mode: :steer_backlog

# The gateway writes channel-bound files into the agent's workspace, but must
# not depend on the agent product; the reference runtime forwards the value.
config :lemon_gateway, :workspace_dir, {CodingAgent.Config, :workspace_dir, []}

config :lemon_router, :engine_runtime, LemonGateway.Runtime

# Support bundles include workspace (goal/kanban) diagnostics when the agent
# runtime is present. lemon_core must not reference agent_core directly.
config :lemon_core, :workspace_diagnostics,
  goal: LemonAgent.Workspace.GoalStore,
  kanban: LemonAgent.Workspace.KanbanStore

# Same idea for every diagnostic whose subject is owned by another app: the
# doctor framework looks the module up instead of naming it.
# See LemonCore.Doctor.RuntimeModules.
config :lemon_core, :doctor_runtime,
  memory_providers: LemonMemory.Providers,
  memory_store: LemonMemory.Store,
  media_jobs: LemonMedia.MediaJobs,
  media_supervisor: LemonMedia.MediaJobSupervisor,
  browser_artifacts: LemonBrowser.Artifacts,
  browser_server: LemonBrowser.LocalServer,
  lsp_server_manager: LemonLsp.ServerManager,
  channel_diagnostics: LemonChannels.Doctor.Diagnostics,
  channel_readiness: LemonChannels.Doctor.Readiness,
  channel_proofs: LemonChannels.Doctor.ProofSpec

# Diagnostics owned by apps that depend on lemon_core register themselves here.
# Modules missing from a given build are skipped (see LemonCore.Doctor).
config :lemon_core, :doctor_checks, [
  LemonAutomation.Doctor.Checks.Synthesis,
  LemonChannels.Doctor.Checks.Channels
]

# Per-platform `[gateway.<id>]` config sections. Each module owns its section,
# its `enable_<id>` flag, its environment variables and its validation rules,
# so LemonCore.Config.Gateway never names a chat platform.
# See LemonCore.Config.Gateway.Channel.
config :lemon_core, :gateway_channels, [
  LemonChannels.Adapters.Telegram.Config,
  LemonChannels.Adapters.Discord.Config,
  LemonChannels.Adapters.Xmtp.Config
]

# Environment-variable declarations live with the app that reads them; the
# framework in LemonCore.Env aggregates whatever is loaded. Apps missing from a
# given build are skipped, so this list is a superset, not a requirement.
config :lemon_core, :env_registries, [
  LemonCore.Env.Declarations,
  LemonAi.Env,
  LemonAgent.Env,
  LemonCliRunners.Env,
  CodingAgent.Env,
  LemonAutomation.Env,
  LemonBrowser.Env,
  LemonChannels.Env,
  LemonControlPlane.Env,
  LemonEvals.Env,
  LemonGateway.Env,
  LemonHoncho.Env,
  LemonRouter.Env,
  LemonSkills.Env,
  LemonWeb.Env,
  XApi.Env,
  # lemon-sim product block — moves to the lemon-sim repo (docs/platform-split.md Phase 5)
  LemonSimUi.Env,
  LemonTcg.Env
]

config :lemon_channels,
  adapters: [
    LemonChannels.Adapters.Telegram,
    LemonChannels.Adapters.Discord,
    LemonChannels.Adapters.Xmtp,
    LemonChannels.Adapters.WhatsApp,
    LemonChannels.Adapters.Email
  ]

# Email is registered but inert: its `start_link/0` returns `:ignore`, so it
# occupies no process, and inbound mail arrives only once a host enables
# LemonChannels.InboundHttp and sets a webhook token. That mirrors the gateway
# transport it replaced, which was also off by default.

# The X adapter is not listed above on purpose: it lives in the x_api satellite
# and registers itself at boot (see XApi.Application), so the platform's config
# does not name it either.

# Filesystem layout for the reference runtime. These are LemonCore.Paths'
# defaults, stated explicitly so the values live with the runtime rather than
# inside the library.
config :lemon_core, :paths,
  state_dir: ".lemon",
  config_file: "config.toml"

# Master key providers for encrypted secrets, tried in order. `:keychain` is
# macOS-only and skips itself elsewhere; see LemonCore.Secrets.KeyProvider.
config :lemon_core, LemonCore.Secrets,
  key_providers: [:keychain, :env, :file],
  key_file: "~/.lemon/secrets_master_key",
  env_var: "LEMON_SECRETS_MASTER_KEY"

# Default to an in-memory store. Dev/prod override to disk-backed persistence.
#
# The store is a storage primitive and must not name its collaborators, so the
# runtime wires them here: run history and memory ingest attach as finalize-run
# hooks, and run-history reads forward to the same provider. Channels register
# their own cached tables at boot (see LemonChannels.Application).
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: [],
  finalize_run_hooks: [
    {LemonCore.RunHistoryStore, :handle_finalize_run},
    {LemonMemory.Ingest, :handle_finalize_run}
  ],
  run_history_provider: LemonCore.RunHistoryStore

config :lemon_web, LemonWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: LemonWeb.ErrorHTML, json: LemonWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LemonCore.PubSub,
  live_view: [signing_salt: "lemonwebsigningsalt"]

config :lemon_web, :access_token, nil
config :lemon_web, :uploads_dir, Path.join(System.tmp_dir!(), "lemon_web_uploads")

# Phoenix endpoints whose HTTP port LemonCore.Runtime.Env.apply_ports/1 rewrites
# at boot, as {port_field_on_the_Env_struct, otp_app, endpoint_module}. Declared
# here rather than in lemon_core so the platform never names a product's module.
config :lemon_core, :runtime_endpoints, [
  {:web_port, :lemon_web, LemonWeb.Endpoint},
  # lemon-sim product block — moves to the lemon-sim repo (see docs/platform-split.md Phase 5)
  {:sim_port, :lemon_sim_ui, LemonSimUi.Endpoint}
]

# ── lemon-sim product block — moves to the lemon-sim repo (docs/platform-split.md Phase 5) ──
config :lemon_sim_ui, LemonSimUi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: LemonSimUi.ErrorHTML, json: LemonSimUi.ErrorJSON],
    layout: false
  ],
  pubsub_server: LemonCore.PubSub,
  live_view: [signing_salt: "lemonsimuilv"]

config :lemon_sim_ui, :access_token, nil
config :lemon_sim_ui, :allow_insecure_admin, false
config :lemon_sim_ui, :admin_session_ttl_seconds, 28_800
config :lemon_sim_ui, :public_vending_launcher, false
config :lemon_sim_ui, :max_concurrent_runners, 8
config :lemon_sim_ui, :max_stored_simulations, 500
config :lemon_sim_ui, :hosted_rooms_enabled, false
config :lemon_sim_ui, :hosted_room_create_token, nil
config :lemon_sim_ui, :hosted_room_limit, 100
config :lemon_sim_ui, :hosted_room_retention, 500
config :lemon_sim_ui, :hosted_lobby_ttl_seconds, 86_400
config :lemon_sim_ui, :hosted_inactive_ttl_seconds, 604_800
config :lemon_sim_ui, :hosted_ai_model, nil
config :lemon_sim_ui, :hosted_ai_concurrency, 4

# Always-on model arenas (leagues). Each domain stays disabled unless its
# LEMON_ARENA_<DOMAIN>_MODELS env is provided at runtime; see config/runtime.exs.
config :lemon_sim_ui, :arenas, []

# ── end lemon-sim product block ──

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

import_config "#{config_env()}.exs"
