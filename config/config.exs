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

# Codex CLI runner configuration (AgentCore)
config :agent_core, :codex,
  # Extra arguments passed to `codex` before `exec`.
  # Defaults to ["-c", "notify=[]"] if not set.
  extra_args: ["-c", "notify=[]"],
  # When true, adds `--dangerously-bypass-approvals-and-sandbox` for full auto.
  auto_approve: false

# Claude CLI runner configuration (AgentCore)
config :agent_core, :claude,
  # When true, adds `--dangerously-skip-permissions` for full auto mode.
  # This allows Claude subagents to run without permission prompts.
  dangerously_skip_permissions: true

# Lane concurrency caps for CodingAgent.LaneQueue
config :coding_agent, :lane_caps,
  main: 4,
  subagent: 8,
  background_exec: 2

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
