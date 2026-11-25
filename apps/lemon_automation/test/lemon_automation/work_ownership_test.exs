defmodule LemonAutomation.WorkOwnershipTest do
  @moduledoc """
  Goal and kanban state, authority, agent tools and chat commands are owned by
  lemon_automation (#721, #729). The generic agent runtime ships none of them,
  skills and channels reach none of them by a hidden module name, and the tools
  keep their schemas after moving into the runtime tool registry.
  """

  use ExUnit.Case, async: false

  @owned [
    LemonAutomation.GoalStore,
    LemonAutomation.GoalAuthority,
    LemonAutomation.KanbanStore,
    LemonAutomation.KanbanAuthority,
    LemonAutomation.Tools.Goal,
    LemonAutomation.Tools.Kanban,
    LemonAutomation.ChatCommands
  ]

  # `:erlang.phash2({name, label, description, parameters})` of each tool as
  # it shipped from lemon_skills before the move.
  @schema_hashes %{"kanban" => 52_020_404, "goal" => 113_994_118}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    :ok
  end

  test "lemon_automation owns the goal and kanban modules" do
    automation = Application.spec(:lemon_automation, :modules)

    for module <- @owned do
      assert module in automation
    end

    for app <- [:lemon_agent, :lemon_skills, :lemon_channels],
        module <- Application.spec(app, :modules) do
      refute inspect(module) =~ ~r/\.(Goal|Kanban)(Store|Authority|StatusMessage)?$/,
             "#{inspect(module)} still ships in #{app}"
    end
  end

  test "kanban and goal are registered runtime tools with unchanged schemas" do
    entries = LemonAgent.ToolRegistry.all()

    for {name, module} <- [kanban: LemonAutomation.Tools.Kanban, goal: LemonAutomation.Tools.Goal] do
      assert {name, module, :managed} in entries
      assert LemonCore.ToolCatalog.registrable?(Atom.to_string(name))

      tool = module.tool("/tmp", [])

      assert :erlang.phash2({tool.name, tool.label, tool.description, tool.parameters}) ==
               Map.fetch!(@schema_hashes, tool.name)
    end
  end

  test "channels reach chat automation through the core command seam" do
    assert LemonCore.AutomationCommands.provider() == LemonAutomation.ChatCommands
  end
end
