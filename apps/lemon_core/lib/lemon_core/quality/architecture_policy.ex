defmodule LemonCore.Quality.ArchitecturePolicy do
  @moduledoc """
  Canonical source of truth for architecture dependency policy.

  This module defines which umbrella apps may directly depend on which other
  umbrella apps. The current policy is enforced; the target policy captures the
  tighter post-migration shape and is used for non-failing drift reports.
  """

  @type app :: atom()
  @type dependency_map :: %{optional(app()) => [app()]}

  @current_allowed_direct_deps %{
    lemon_agent: [:lemon_ai, :lemon_core],
    lemon_ai: [],
    coding_agent: [
      :lemon_agent,
      :lemon_ai,
      :lemon_browser,
      :lemon_core,
      :lemon_gateway,
      :lemon_memory,
      # test-only: shared platform compliance cases
      :lemon_platform_test,
      :lemon_skills
    ],
    coding_agent_ui: [:coding_agent, :lemon_core],
    lemon_automation: [:lemon_agent, :lemon_core, :lemon_router, :lemon_skills],
    lemon_channels: [:lemon_agent, :lemon_core, :lemon_media],
    lemon_control_plane: [
      :lemon_ai,
      :lemon_agent,
      :lemon_automation,
      :lemon_browser,
      :lemon_channels,
      :lemon_core,
      :lemon_lsp,
      :lemon_media,
      :lemon_memory,
      :lemon_router,
      :lemon_skills
    ],
    lemon_cli: [:lemon_ai, :lemon_core, :lemon_memory],
    lemon_browser: [:lemon_core],
    lemon_core: [],
    lemon_memory: [:lemon_core],
    lemon_evals: [
      :lemon_agent,
      :lemon_ai,
      :coding_agent,
      :lemon_core,
      :lemon_skills
    ],
    lemon_gateway: [
      :lemon_agent,
      :lemon_ai,
      :lemon_automation,
      :lemon_core
    ],
    # A satellite: it implements platform contracts (a memory provider, a
    # context contributor, agent tools) and registers itself on the way up, so
    # it depends on the platform while nothing in the platform names it.
    # test-only: proves its provider against the published contract kit.
    lemon_honcho: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_memory, :lemon_platform_test],
    lemon_lsp: [:lemon_core],
    lemon_media: [:lemon_core],
    lemon_mcp: [:lemon_agent, :coding_agent, :lemon_core, :lemon_skills],
    # The contract-test kit is a leaf: one (optional) dep per behaviour it
    # tests, and nothing in the platform depends on it outside test code. ai +
    # agent_core back the FakeLLM double, which drives a real agent loop.
    lemon_platform_test: [
      :lemon_agent,
      :lemon_ai,
      :lemon_channels,
      :lemon_core,
      :lemon_gateway,
      :lemon_memory
    ],
    lemon_router: [
      :lemon_agent,
      :lemon_ai,
      :lemon_channels,
      :lemon_core,
      :lemon_media,
      :lemon_memory
    ],
    lemon_sim: [:lemon_agent, :lemon_ai, :lemon_core],
    lemon_sim_ui: [:lemon_ai, :lemon_core, :lemon_sim],
    lemon_skills: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_media, :lemon_memory],
    lemon_tcg: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_sim],
    lemon_web: [:lemon_core, :lemon_router],
    # test-only: runs XApi.ChannelAdapter through the Plugin contract kit
    x_api: [:lemon_agent, :lemon_ai, :lemon_channels, :lemon_core, :lemon_platform_test]
  }

  @target_allowed_direct_deps @current_allowed_direct_deps
                              |> Map.update!(:lemon_gateway, fn deps ->
                                deps -- [:lemon_ai, :lemon_automation, :lemon_channels]
                              end)

  @spec current_allowed_direct_deps() :: dependency_map()
  def current_allowed_direct_deps do
    normalize_dependency_map(@current_allowed_direct_deps)
  end

  @spec allowed_direct_deps() :: dependency_map()
  def allowed_direct_deps do
    current_allowed_direct_deps()
  end

  @spec target_allowed_direct_deps() :: dependency_map()
  def target_allowed_direct_deps do
    normalize_dependency_map(@target_allowed_direct_deps)
  end

  defp normalize_dependency_map(deps) do
    deps
    |> Enum.map(fn {app, deps} -> {app, Enum.sort(deps)} end)
    |> Map.new()
  end
end
