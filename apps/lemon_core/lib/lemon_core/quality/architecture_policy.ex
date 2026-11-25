defmodule LemonCore.Quality.ArchitecturePolicy do
  @moduledoc """
  Architecture rules for the umbrella dependency graph.

  `apps/*/mix.exs` is the only source of the declared graph; this module never
  restates it. Instead it names the roles the graph must respect:

    * namespaces - the module prefixes each app owns, so a source reference can
      be attributed to the app that defines it
    * foundations - apps with no umbrella dependencies at all
    * satellites - apps nothing else may depend on; they register themselves
      through platform seams at boot
    * test kits - apps other apps may only depend on with `only: :test`
    * reference-only seams - cross-app namespaces an app may name without a
      Mix edge, because they are dispatched at runtime by an entrypoint that
      nothing depends on. A seam never authorizes a `mix.exs` edge and must
      still be used.
    * config bindings - modules `config/*.exs` hands to an app that neither
      depends on the module's owner nor is depended on by it (composition-root
      wiring). Bindings join the cycle check and must still appear in config.

  `LemonCore.Quality.ArchitectureCheck` derives every other rule (acyclic
  graph, referenced edges, hidden reference forms) from these roles and the
  sources.
  """

  @type app :: atom()
  @type dependency_map :: %{optional(app()) => [app()]}

  @app_namespaces %{
    coding_agent: ["CodingAgent"],
    lemon_agent: ["LemonAgent"],
    lemon_ai: ["LemonAi"],
    lemon_automation: ["LemonAutomation"],
    lemon_browser: ["LemonBrowser"],
    lemon_channels: ["LemonChannels"],
    lemon_cli: ["LemonCli"],
    lemon_computer_use: ["LemonComputerUse"],
    lemon_control_plane: ["LemonControlPlane"],
    lemon_core: ["LemonCore"],
    lemon_evals: ["LemonEvals"],
    lemon_gateway: ["LemonGateway"],
    lemon_honcho: ["LemonHoncho"],
    lemon_lsp: ["LemonLsp"],
    lemon_media: ["LemonMedia"],
    lemon_memory: ["LemonMemory"],
    lemon_omp: ["LemonOmp"],
    lemon_platform_test: ["LemonPlatformTest"],
    lemon_router: ["LemonRouter"],
    # The MCP client library ships inside lemon_skills, its only owner.
    lemon_skills: ["LemonSkills", "LemonMCP"],
    lemon_web: ["LemonWeb"]
  }

  # Published foundations: neither may acquire an umbrella dependency merely to
  # share a mechanism (docs/architecture_boundaries.md).
  @foundations [:lemon_ai, :lemon_core]

  # Satellites implement platform contracts and register on the way up, and
  # product entrypoints sit on top of the graph; nothing may depend on them.
  @satellites [:lemon_cli, :lemon_computer_use, :lemon_evals, :lemon_gateway, :lemon_honcho, :lemon_web]

  # Contract-test kits back test suites only; a lib edge would ship test code.
  @test_kits [:lemon_platform_test]

  @reference_only_seams %{
    # The shared CLI registry dispatches Mix-free runtime command handlers in
    # their owning apps; one-shot commands such as setup must not start those
    # applications through a Mix edge.
    lemon_cli: [:coding_agent, :lemon_channels, :lemon_media, :lemon_router],
    # Gateway tools build LemonAi content structs; lemon_agent already brings
    # lemon_ai into every gateway build.
    lemon_gateway: [:lemon_ai]
  }

  @config_bindings %{
    # LemonCore.Env aggregates the environment declarations of every loaded
    # app (`config :lemon_core, :env_registries`); lemon_ai is the one
    # declaring app that does not depend on lemon_core.
    lemon_core: [:lemon_ai],
    # Gateway health reports the XMTP channel transport when XMTP is enabled
    # (`config :lemon_gateway, :xmtp_transport_module`).
    lemon_gateway: [:lemon_channels]
  }

  @doc "Namespace prefixes owned by each umbrella app."
  @spec app_namespaces() :: %{optional(app()) => [String.t()]}
  def app_namespaces, do: @app_namespaces

  @doc "Apps that must not declare any umbrella dependency."
  @spec foundations() :: [app()]
  def foundations, do: @foundations

  @doc "Apps no other app may depend on or reference."
  @spec satellites() :: [app()]
  def satellites, do: @satellites

  @doc "Apps other apps may only depend on with `only: :test`."
  @spec test_kits() :: [app()]
  def test_kits, do: @test_kits

  @doc """
  Returns namespace owners that an app may reference without declaring a direct
  umbrella dependency. These never authorize a `mix.exs` edge.
  """
  @spec reference_only_namespace_exceptions() :: dependency_map()
  def reference_only_namespace_exceptions do
    Map.new(@reference_only_seams, fn {app, owners} -> {app, Enum.sort(owners)} end)
  end

  @doc "Owners whose modules `config :app` may name although the apps are unrelated."
  @spec config_bindings() :: dependency_map()
  def config_bindings do
    Map.new(@config_bindings, fn {app, owners} -> {app, Enum.sort(owners)} end)
  end
end
