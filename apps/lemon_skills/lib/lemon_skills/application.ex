defmodule LemonSkills.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure ~/.lemon/agent/skill exists before the registry loads from disk.
    LemonSkills.Config.ensure_dirs!()
    # Copy repo-bundled skills into the user's global config dir if missing.
    LemonSkills.BuiltinSeeder.seed!()
    # Back-fill lockfile provenance for any pre-existing installs.
    LemonSkills.Migrator.migrate()
    LemonSkills.Telemetry.attach_introspection_bridge()
    # Automatic per-turn memory recall. Registered once at boot; the contributor
    # itself skips turns when `[memory] auto_recall = false`.
    LemonAgent.ContextRegistry.register(:memory_recall, LemonSkills.MemoryRecall)
    LemonAgent.ContextRegistry.register(:learning_nudge, LemonSkills.LearningNudge)

    children = [
      LemonSkills.Registry,
      LemonSkills.LearningNudge,
      # MCP source for external tool discovery
      {LemonSkills.McpSource, []},
      {DynamicSupervisor, strategy: :one_for_one, name: LemonSkills.McpSession.Supervisor},
      LemonSkills.McpSession
    ]

    opts = [strategy: :one_for_one, name: LemonSkills.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
