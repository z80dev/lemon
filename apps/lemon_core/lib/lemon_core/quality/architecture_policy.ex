defmodule LemonCore.Quality.ArchitecturePolicy do
  @moduledoc """
  Canonical source of truth for architecture dependency policy.

  This module defines which umbrella apps may directly depend on which other
  umbrella apps. The direct-dependency policy is exact: permissions that no
  longer appear in `mix.exs` are stale and fail the architecture check.

  Cross-app source references that intentionally do not create a direct Mix
  dependency are listed separately as reference-only exceptions. An exception
  permits namespace use; it never permits adding a dependency to `mix.exs`.
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
      :lemon_mcp,
      :lemon_memory,
      # test-only: shared platform compliance cases
      :lemon_platform_test,
      :lemon_skills
    ],
    lemon_automation: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_router, :lemon_skills],
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
      :lemon_omp,
      :lemon_router,
      :lemon_skills
    ],
    lemon_cli: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_memory, :lemon_skills],
    lemon_browser: [:lemon_core],
    lemon_core: [],
    lemon_memory: [:lemon_core],
    lemon_evals: [
      :lemon_agent,
      :lemon_ai,
      :coding_agent,
      :lemon_core,
      :lemon_memory,
      :lemon_skills
    ],
    lemon_gateway: [:lemon_agent, :lemon_core],
    # A satellite: it implements platform contracts (a memory provider, a
    # context contributor, agent tools) and registers itself on the way up, so
    # it depends on the platform while nothing in the platform names it.
    # test-only: proves its provider against the published contract kit.
    lemon_honcho: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_memory, :lemon_platform_test],
    lemon_lsp: [:lemon_core],
    lemon_media: [:lemon_core],
    # test-only: lemon_skills hosts the moved LemonSkills.McpSource suite.
    lemon_mcp: [:lemon_core, :lemon_skills],
    # The omp delegate driver implements the agent tool contract and registers
    # its `omp` tool at boot; the coding product never names it. The control
    # plane depends on it directly to expose `omp.*` methods.
    lemon_omp: [:lemon_agent, :lemon_ai, :lemon_core],
    # The contract-test kit is a leaf: one (optional) dep per behaviour it
    # tests, and nothing in the platform depends on it outside test code. ai +
    # agent_core back the FakeLLM double, which drives a real agent loop.
    lemon_platform_test: [
      :lemon_agent,
      :lemon_ai,
      :lemon_channels,
      :lemon_core,
      :lemon_memory
    ],
    lemon_router: [
      :lemon_agent,
      :lemon_ai,
      :lemon_channels,
      :lemon_core,
      :lemon_mcp,
      :lemon_media,
      :lemon_memory
    ],
    lemon_sim: [:lemon_agent, :lemon_ai, :lemon_core],
    lemon_sim_ui: [:lemon_ai, :lemon_core, :lemon_sim],
    lemon_skills: [:lemon_agent, :lemon_ai, :lemon_core, :lemon_media, :lemon_memory],
    # The web UI is an in-process client of the control-plane method registry
    # and event projection (the same contract as the TUI), and consumes
    # agent-owned provider configuration, automation-owned blueprint catalog,
    # and memory-owned lifecycle boundaries; mutation, confirmation, and
    # redaction semantics stay centralized in their domain services.
    lemon_web: [
      :lemon_agent,
      :lemon_automation,
      :lemon_control_plane,
      :lemon_core,
      :lemon_memory,
      :lemon_router
    ]
  }

  # Gateway tools still use LemonAi content structs without making it a direct
  # dependency. Keeping these exceptions separate prevents them from silently
  # authorizing a future mix.exs edge.
  @reference_only_namespace_exceptions %{
    # The shared CLI registry invokes these bundled runtime command handlers
    # dynamically; setup must not start channel services through a Mix edge.
    lemon_cli: [:lemon_channels, :lemon_media],
    lemon_gateway: [:lemon_ai]
  }

  @target_allowed_direct_deps @current_allowed_direct_deps

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

  @doc """
  Returns namespace owners that an app may reference without declaring a direct
  umbrella dependency.

  These are source-reference exceptions only. They are deliberately excluded
  from `allowed_direct_deps/0`.
  """
  @spec reference_only_namespace_exceptions() :: dependency_map()
  def reference_only_namespace_exceptions do
    normalize_dependency_map(@reference_only_namespace_exceptions)
  end

  defp normalize_dependency_map(deps) do
    deps
    |> Enum.map(fn {app, deps} -> {app, Enum.sort(deps)} end)
    |> Map.new()
  end
end
