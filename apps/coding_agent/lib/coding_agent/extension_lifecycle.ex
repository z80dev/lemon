defmodule CodingAgent.ExtensionLifecycle do
  @moduledoc """
  Coordinates extension discovery/reload and derived session artifacts.

  This module centralizes extension lifecycle concerns that were previously
  implemented directly in `CodingAgent.Session`, including:

  - extension path resolution
  - extension load/reload
  - provider registration cleanup + registration
  - tool rebuild, including the `CodingAgent.Extensions.ToolHooks` interception
    wrapper (applied after approval wrapping and before tool disclosure, so
    hidden tools reached through `tool_invoke` are intercepted too)
  - extension status report construction
  """

  alias CodingAgent.Config
  alias CodingAgent.Extensions
  alias CodingAgent.Extensions.ToolHooks
  alias CodingAgent.Security.SecretObfuscator
  alias CodingAgent.ToolDisclosure
  alias CodingAgent.ToolPolicy
  alias CodingAgent.ToolRegistry
  alias LemonAgent.Types.AgentTool

  @type lifecycle_result :: %{
          extensions: [module()],
          hooks: keyword([function()]),
          tools: [AgentTool.t()],
          tool_catalog: ToolDisclosure.catalog(),
          extension_status_report: Extensions.extension_status_report(),
          extension_paths: [String.t()],
          provider_registration: Extensions.provider_registration_report(),
          wasm_status: map() | nil,
          tool_disclosure: ToolDisclosure.report()
        }

  @doc """
  Initialize extension lifecycle data for session startup.
  """
  @spec initialize(keyword()) :: lifecycle_result()
  def initialize(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    config_cwd = Keyword.get(opts, :config_cwd) || cwd
    settings_manager = Keyword.fetch!(opts, :settings_manager)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    custom_tools = Keyword.get(opts, :custom_tools)
    extra_tools = Keyword.get(opts, :extra_tools, [])
    wasm_tools = Keyword.get(opts, :wasm_tools, [])
    wasm_status = Keyword.get(opts, :wasm_status)
    tool_policy = session_policy(opts, tool_opts)

    approval_context =
      Keyword.get(opts, :approval_context, Keyword.get(tool_opts, :approval_context))

    extension_paths = extension_paths(config_cwd, settings_manager)

    {extensions, load_errors} =
      case Keyword.fetch(tool_opts, :extension_inventory) do
        {:ok, {extensions, load_errors}} ->
          {extensions, load_errors}

        :error ->
          inventory = load_extensions(extension_paths)
          {extensions, load_errors} = inventory
          ToolRegistry.prime_extension_cache(cwd, extension_paths, extensions, load_errors)
          inventory
      end

    hooks = Extensions.get_hooks(extensions)
    provider_registration = Extensions.register_extension_providers(extensions)

    tool_opts =
      tool_opts
      |> Keyword.put(:config_cwd, config_cwd)
      |> Keyword.put(:extension_paths, extension_paths)
      |> Keyword.put(:wasm_tools, wasm_tools)
      |> Keyword.put(:wasm_status, wasm_status)
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:approval_context, approval_context)
      # Tools and the conflict report share one browser provider probe.
      |> ToolRegistry.put_browser_provider_resolution()

    disclosure_cfg =
      ToolDisclosure.config(
        settings_manager,
        Keyword.get(tool_opts, :tool_disclosure),
        Keyword.get(tool_opts, :session_mode, :chat)
      )

    {tools, tool_catalog, disclosure_report} =
      build_tools(
        cwd,
        tool_opts,
        custom_tools,
        extra_tools,
        disclosure_cfg,
        hooks,
        Keyword.get(opts, :secret_obfuscator)
      )

    emit_disclosure_telemetry(disclosure_report)

    tool_conflict_report = ToolRegistry.tool_conflict_report(cwd, tool_opts)

    extension_status_report =
      Extensions.build_status_report(extensions, load_errors,
        cwd: cwd,
        tool_conflict_report: tool_conflict_report,
        provider_registration: provider_registration
      )
      |> maybe_attach_wasm_status(wasm_status)
      |> Map.put(:tool_disclosure, disclosure_report)

    %{
      extensions: extensions,
      hooks: hooks,
      tools: tools,
      tool_catalog: tool_catalog,
      extension_status_report: extension_status_report,
      extension_paths: extension_paths,
      provider_registration: provider_registration,
      wasm_status: wasm_status,
      tool_disclosure: disclosure_report
    }
  end

  @doc """
  Reload extension lifecycle data for a running session.

  Recompiles only the session's configured sources. Removed modules are unloaded
  only when no other cached working-directory inventory uses them.
  """
  @spec reload(keyword()) :: lifecycle_result()
  def reload(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    config_cwd = Keyword.get(opts, :config_cwd) || cwd
    settings_manager = Keyword.fetch!(opts, :settings_manager)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    custom_tools = Keyword.get(opts, :custom_tools)
    extra_tools = Keyword.get(opts, :extra_tools, [])
    wasm_tools = Keyword.get(opts, :wasm_tools, [])
    wasm_status = Keyword.get(opts, :wasm_status)
    tool_policy = session_policy(opts, tool_opts)

    approval_context =
      Keyword.get(opts, :approval_context, Keyword.get(tool_opts, :approval_context))

    previous_status_report = Keyword.get(opts, :previous_status_report)

    old_provider_registration =
      case previous_status_report do
        %{provider_registration: reg} -> reg
        _ -> nil
      end

    Extensions.unregister_extension_providers(old_provider_registration)

    extension_paths = extension_paths(config_cwd, settings_manager)
    ToolRegistry.invalidate_extension_cache(cwd)

    {extensions, load_errors} = load_extensions(extension_paths)
    ToolRegistry.prime_extension_cache(cwd, extension_paths, extensions, load_errors)
    unload_removed_extensions(previous_status_report, extensions)

    hooks = Extensions.get_hooks(extensions)
    provider_registration = Extensions.register_extension_providers(extensions)

    tool_opts =
      tool_opts
      |> Keyword.put(:config_cwd, config_cwd)
      |> Keyword.put(:extension_paths, extension_paths)
      |> Keyword.put(:wasm_tools, wasm_tools)
      |> Keyword.put(:wasm_status, wasm_status)

    tool_opts =
      tool_opts
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:approval_context, approval_context)
      |> ToolRegistry.put_browser_provider_resolution()

    disclosure_cfg =
      ToolDisclosure.config(
        settings_manager,
        Keyword.get(tool_opts, :tool_disclosure),
        Keyword.get(tool_opts, :session_mode, :chat)
      )

    {tools, tool_catalog, disclosure_report} =
      build_tools(
        cwd,
        tool_opts,
        custom_tools,
        extra_tools,
        disclosure_cfg,
        hooks,
        Keyword.get(opts, :secret_obfuscator)
      )

    emit_disclosure_telemetry(disclosure_report)

    tool_conflict_report = ToolRegistry.tool_conflict_report(cwd, tool_opts)

    extension_status_report =
      Extensions.build_status_report(extensions, load_errors,
        cwd: cwd,
        tool_conflict_report: tool_conflict_report,
        provider_registration: provider_registration
      )
      |> maybe_attach_wasm_status(wasm_status)
      |> Map.put(:tool_disclosure, disclosure_report)

    %{
      extensions: extensions,
      hooks: hooks,
      tools: tools,
      tool_catalog: tool_catalog,
      extension_status_report: extension_status_report,
      extension_paths: extension_paths,
      provider_registration: provider_registration,
      wasm_status: wasm_status,
      tool_disclosure: disclosure_report
    }
  end

  @doc """
  Rebuild tools for new options from the already loaded extensions and hooks.

  Used when reset changes the session identity captured by tool closures, without
  reloading extensions or providers. Custom toolsets retain their startup tools.
  """
  @spec rebuild_tools(keyword()) :: %{
          tools: [AgentTool.t()],
          tool_catalog: ToolDisclosure.catalog(),
          tool_disclosure: ToolDisclosure.report()
        }
  def rebuild_tools(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    config_cwd = Keyword.get(opts, :config_cwd) || cwd
    settings_manager = Keyword.fetch!(opts, :settings_manager)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    tool_policy = session_policy(opts, tool_opts)

    approval_context =
      Keyword.get(opts, :approval_context, Keyword.get(tool_opts, :approval_context))

    tool_opts =
      tool_opts
      |> Keyword.put(:config_cwd, config_cwd)
      |> Keyword.put(:extension_paths, extension_paths(config_cwd, settings_manager))
      |> Keyword.put(:wasm_tools, Keyword.get(opts, :wasm_tools, []))
      |> Keyword.put(:wasm_status, Keyword.get(opts, :wasm_status))
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:approval_context, approval_context)
      |> ToolRegistry.put_browser_provider_resolution()

    disclosure_cfg =
      ToolDisclosure.config(
        settings_manager,
        Keyword.get(tool_opts, :tool_disclosure),
        Keyword.get(tool_opts, :session_mode, :chat)
      )

    {tools, tool_catalog, disclosure_report} =
      build_tools(
        cwd,
        tool_opts,
        Keyword.get(opts, :custom_tools),
        Keyword.get(opts, :extra_tools, []),
        disclosure_cfg,
        Keyword.fetch!(opts, :hooks),
        Keyword.get(opts, :secret_obfuscator)
      )

    emit_disclosure_telemetry(disclosure_report)

    %{tools: tools, tool_catalog: tool_catalog, tool_disclosure: disclosure_report}
  end

  @doc """
  Resolve extension search paths for a working directory and settings.
  """
  @spec extension_paths(String.t(), term()) :: [String.t()]
  def extension_paths(cwd, settings_manager) do
    settings_paths =
      case settings_manager do
        %{extension_paths: paths} when is_list(paths) -> paths
        _ -> []
      end

    default_paths =
      if auto_load_default_paths?(settings_manager) do
        [
          Config.extensions_dir(),
          Config.project_extensions_dir(cwd)
        ]
      else
        []
      end

    settings_paths ++ default_paths
  end

  defp auto_load_default_paths?(%{extension_auto_load_default_paths: true}), do: true
  defp auto_load_default_paths?(_), do: false

  @spec load_extensions([String.t()]) :: {[module()], [Extensions.load_error()]}
  defp load_extensions(extension_paths) do
    {:ok, extensions, load_errors, _validation_errors} =
      Extensions.load_extensions_with_errors(extension_paths)

    {extensions, load_errors}
  end

  defp unload_removed_extensions(%{extensions: previous}, extensions) when is_list(previous) do
    previous
    |> Enum.map(& &1.module)
    |> Kernel.--(extensions)
    |> ToolRegistry.unload_uncached_extensions()
  end

  defp unload_removed_extensions(_previous_status_report, _extensions), do: :ok

  # Every tool list a session sees is finalized here: registry tuples come back
  # from `ToolRegistry.get_tool_tuples/2` already filtered and gated, and
  # caller-supplied tools go through `ToolRegistry.finalize_tools/3`, the same
  # policy floor and approval gate.
  @spec build_tools(
          String.t(),
          keyword(),
          [AgentTool.t()] | nil,
          [AgentTool.t()],
          ToolDisclosure.config(),
          keyword([function()]),
          SecretObfuscator.t() | nil
        ) :: {[AgentTool.t()], ToolDisclosure.catalog(), ToolDisclosure.report()}
  defp build_tools(cwd, tool_opts, custom_tools, extra_tools, disclosure_cfg, hooks, obfuscator) do
    tool_opts = Keyword.put(tool_opts, :tool_disclosure, disclosure_cfg)

    hook_context = tool_hook_context(cwd, tool_opts)

    terminal_names =
      extra_tools
      |> Enum.filter(&ToolRegistry.trusted_terminal?/1)
      |> Enum.map(& &1.name)

    case custom_tools do
      nil ->
        %{tools: tools, catalog: catalog, report: report} =
          ToolDisclosure.apply(
            cwd
            |> ToolRegistry.get_tool_tuples(tool_opts)
            |> Enum.reject(fn {name, _tool, _source} -> name in terminal_names end)
            |> ToolHooks.wrap_tuples(hooks, hook_context)
            |> SecretObfuscator.wrap_tuples(obfuscator),
            extra_tools
            |> ToolRegistry.finalize_tools(cwd, tool_opts)
            |> ToolHooks.wrap_tools(hooks, hook_context)
            |> SecretObfuscator.wrap_tools(obfuscator),
            disclosure_cfg,
            authority: Keyword.get(tool_opts, :tool_policy),
            finalize_bridges: &ToolRegistry.gate_bridge_tuples(&1, cwd, tool_opts)
          )

        {tools, catalog, report}

      custom ->
        # A hand-assembled toolset is a closed set: exactly these tools plus the
        # caller's extra tools, through the same floor and gate. No extension or
        # registry tool joins it, so there is no long tail to defer and no
        # registry source tags to partition by.
        tools =
          (Enum.reject(custom, &(&1.name in terminal_names)) ++ extra_tools)
          |> ToolRegistry.finalize_tools(cwd, tool_opts)
          |> ToolHooks.wrap_tools(hooks, hook_context)
          |> SecretObfuscator.wrap_tools(obfuscator)

        {tools, ToolDisclosure.catalog_for_tools(tools),
         ToolDisclosure.skipped_report(:custom_tools, disclosure_cfg)}
    end
  end

  # The one place a session-built tool list resolves its policy. Sessions always
  # pass their validated policy, whose root default is full access (see
  # `LemonCore.ExecutionContext.new/1`); a caller that supplies none gets the
  # deny-all floor, never full access.
  defp session_policy(opts, tool_opts) do
    Keyword.get(opts, :tool_policy) || Keyword.get(tool_opts, :tool_policy) ||
      ToolPolicy.deny_all()
  end

  defp tool_hook_context(cwd, tool_opts) do
    %{cwd: cwd, session_id: Keyword.get(tool_opts, :session_id)}
  end

  defp emit_disclosure_telemetry(report) do
    LemonCore.Telemetry.emit(
      [:coding_agent, :tool_disclosure, :applied],
      %{
        hidden_count: report.hidden_count,
        disclosed_count: report.disclosed_count,
        estimated_tokens: report.estimated_tokens,
        disclosed_tokens: report.disclosed_tokens
      },
      %{
        active: report.active,
        catalog_tier: report.catalog_tier,
        reason: report.reason,
        profile: report.profile,
        catalog_digest: report.catalog_digest,
        diagnostic_events_version: 1
      }
    )
  end

  defp maybe_attach_wasm_status(report, nil), do: report
  defp maybe_attach_wasm_status(report, wasm_status), do: Map.put(report, :wasm, wasm_status)
end
