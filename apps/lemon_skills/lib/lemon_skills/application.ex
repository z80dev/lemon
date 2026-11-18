defmodule LemonSkills.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = LemonSkills.SkillRoot.init_uid()
    # Ensure ~/.lemon/agent/skill exists before the registry loads from disk.
    LemonSkills.Config.ensure_dirs!()
    # Copy repo-bundled skills into the user's global config dir if missing.
    LemonSkills.BuiltinSeeder.seed!()
    # Remove staging/activation leftovers of interrupted installs before the
    # Migrator or Registry can see them.
    LemonSkills.Installer.sweep_staging()
    # Back-fill lockfile provenance for any pre-existing installs.
    LemonSkills.Migrator.migrate()
    LemonSkills.Telemetry.attach_introspection_bridge()
    # Automatic per-turn memory recall. Registered once at boot; the contributor
    # itself skips turns when `[memory] auto_recall = false`.
    LemonAgent.ContextRegistry.register(:memory_recall, LemonSkills.MemoryRecall)
    LemonAgent.ContextRegistry.register(:learning_nudge, LemonSkills.LearningNudge)

    children = [
      # Started before the Registry, whose upgrade audits run under it.
      # MCP caller admission policy caps concurrent I/O workers at 128 per runtime.
      Supervisor.child_spec(
        {Task.Supervisor, name: LemonSkills.TaskSupervisor, max_children: 128},
        id: LemonSkills.TaskSupervisor
      ),
      LemonSkills.Registry,
      LemonCore.TaskSupervisor.child_spec(name: LemonSkills.ReviewSupervisor),
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
