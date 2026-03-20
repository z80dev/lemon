defmodule LemonCore.Quality.ArchitecturePolicy do
  @moduledoc """
  Canonical source of truth for architecture dependency policy.

  This module defines which umbrella apps may directly depend on which other
  umbrella apps. Human-readable docs and machine checks must derive from this
  module rather than duplicating policy in multiple places.
  """

  @type app :: atom()
  @type dependency_map :: %{optional(app()) => [app()]}

  @allowed_direct_deps %{
    agent_core: [:ai, :lemon_core],
    ai: [:lemon_core],
    coding_agent: [:agent_core, :ai, :lemon_ai_runtime, :lemon_core, :lemon_skills],
    coding_agent_ui: [:coding_agent],
    lemon_automation: [:lemon_core, :lemon_router],
    lemon_channels: [:lemon_core, :lemon_ai_runtime],
    lemon_ai_runtime: [:ai],
    lemon_control_plane: [
      :ai,
      :coding_agent,
      :lemon_automation,
      :lemon_channels,
      :lemon_core,
      :lemon_games,
      :lemon_gateway,
      :lemon_router,
      :lemon_skills
    ],
    lemon_core: [],
    lemon_games: [:lemon_core],
    lemon_gateway: [
      :agent_core,
      :ai,
      :coding_agent,
      :lemon_automation,
      :lemon_channels,
      :lemon_core
    ],
    lemon_mcp: [:agent_core, :coding_agent],
    lemon_router: [:agent_core, :ai, :coding_agent, :lemon_channels, :lemon_core, :lemon_gateway],
    lemon_sim: [:agent_core, :ai, :lemon_core, :lemon_ai_runtime],
    lemon_services: [],
    lemon_skills: [:agent_core, :ai, :lemon_channels, :lemon_core],
    lemon_web: [:lemon_core, :lemon_games, :lemon_router],
    market_intel: [:agent_core, :lemon_channels, :lemon_core]
  }

  @spec allowed_direct_deps() :: dependency_map()
  def allowed_direct_deps do
    @allowed_direct_deps
    |> Enum.map(fn {app, deps} -> {app, Enum.sort(deps)} end)
    |> Map.new()
  end
end
