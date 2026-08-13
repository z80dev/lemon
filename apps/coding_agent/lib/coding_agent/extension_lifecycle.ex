defmodule CodingAgent.ExtensionLifecycle do
  @moduledoc """
  Coordinates extension discovery/reload and derived session artifacts.

  This module centralizes extension lifecycle concerns that were previously
  implemented directly in `CodingAgent.Session`, including:

  - extension path resolution
  - extension load/reload
  - provider registration cleanup + registration
  - tool rebuild
  - extension status report construction
  """

  alias LemonAgent.Types.AgentTool
  alias CodingAgent.Config
  alias CodingAgent.Extensions
  alias CodingAgent.ToolDisclosure
  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolRegistry

  @type lifecycle_result :: %{
          extensions: [module()],
          hooks: keyword([function()]),
          tools: [AgentTool.t()],
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
    settings_manager = Keyword.fetch!(opts, :settings_manager)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    custom_tools = Keyword.get(opts, :custom_tools)
    extra_tools = Keyword.get(opts, :extra_tools, [])
    wasm_tools = Keyword.get(opts, :wasm_tools, [])
    wasm_status = Keyword.get(opts, :wasm_status)
    tool_policy = Keyword.get(opts, :tool_policy)
    approval_context = Keyword.get(opts, :approval_context)

    extension_paths = extension_paths(cwd, settings_manager)
    {extensions, load_errors} = load_extensions(extension_paths)

    # Prime registry cache so lookups in this lifecycle run do not reload extensions.
    ToolRegistry.prime_extension_cache(cwd, extension_paths, extensions, load_errors)

    hooks = Extensions.get_hooks(extensions)
    provider_registration = Extensions.register_extension_providers(extensions)

    tool_opts =
      tool_opts
      |> Keyword.put(:extension_paths, extension_paths)
      |> Keyword.put(:wasm_tools, wasm_tools)
      |> Keyword.put(:wasm_status, wasm_status)

    disclosure_cfg =
      ToolDisclosure.config(settings_manager, Keyword.get(tool_opts, :tool_disclosure))

    {tools, disclosure_report} =
      build_tools(
        cwd,
        tool_opts,
        extensions,
        custom_tools,
        extra_tools,
        tool_policy,
        approval_context,
        disclosure_cfg
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
      extension_status_report: extension_status_report,
      extension_paths: extension_paths,
      provider_registration: provider_registration,
      wasm_status: wasm_status,
      tool_disclosure: disclosure_report
    }
  end

  @doc """
  Reload extension lifecycle data for a running session.
  """
  @spec reload(keyword()) :: lifecycle_result()
  def reload(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    settings_manager = Keyword.fetch!(opts, :settings_manager)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    extra_tools = Keyword.get(opts, :extra_tools, [])
    wasm_tools = Keyword.get(opts, :wasm_tools, [])
    wasm_status = Keyword.get(opts, :wasm_status)
    tool_policy = Keyword.get(opts, :tool_policy)
    approval_context = Keyword.get(opts, :approval_context)
    previous_status_report = Keyword.get(opts, :previous_status_report)

    old_provider_registration =
      case previous_status_report do
        %{provider_registration: reg} -> reg
        _ -> nil
      end

    Extensions.unregister_extension_providers(old_provider_registration)
    Extensions.clear_extension_cache()

    extension_paths = extension_paths(cwd, settings_manager)
    ToolRegistry.invalidate_extension_cache(cwd)

    {extensions, load_errors} = load_extensions(extension_paths)
    ToolRegistry.prime_extension_cache(cwd, extension_paths, extensions, load_errors)

    hooks = Extensions.get_hooks(extensions)
    provider_registration = Extensions.register_extension_providers(extensions)

    tool_opts =
      tool_opts
      |> Keyword.put(:extension_paths, extension_paths)
      |> Keyword.put(:wasm_tools, wasm_tools)
      |> Keyword.put(:wasm_status, wasm_status)

    tool_opts =
      if tool_policy && approval_context do
        tool_opts
        |> Keyword.put(:tool_policy, tool_policy)
        |> Keyword.put(:approval_context, approval_context)
      else
        tool_opts
      end

    disclosure_cfg =
      ToolDisclosure.config(settings_manager, Keyword.get(tool_opts, :tool_disclosure))

    %{tools: tools, report: disclosure_report} =
      ToolDisclosure.apply(
        ToolRegistry.get_tool_tuples(cwd, tool_opts),
        extra_tools,
        disclosure_cfg
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
      extension_status_report: extension_status_report,
      extension_paths: extension_paths,
      provider_registration: provider_registration,
      wasm_status: wasm_status,
      tool_disclosure: disclosure_report
    }
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

  @spec build_tools(
          String.t(),
          keyword(),
          [module()],
          [AgentTool.t()] | nil,
          [AgentTool.t()],
          term(),
          term(),
          ToolDisclosure.config()
        ) :: {[AgentTool.t()], ToolDisclosure.report()}
  defp build_tools(
         cwd,
         tool_opts,
         extensions,
         custom_tools,
         extra_tools,
         tool_policy,
         approval_context,
         disclosure_cfg
       ) do
    case custom_tools do
      nil ->
        %{tools: tools, report: report} =
          ToolDisclosure.apply(
            ToolRegistry.get_tool_tuples(cwd, tool_opts),
            extra_tools,
            disclosure_cfg
          )

        {tools, report}

      custom ->
        extension_tools = Extensions.get_tools(extensions, cwd)
        all_tools = custom ++ extension_tools ++ extra_tools

        tools =
          if tool_policy && approval_context do
            ToolExecutor.wrap_all_with_approval(
              all_tools,
              tool_policy,
              approval_context
            )
          else
            all_tools
          end

        # A hand-assembled toolset is the caller's business: they chose exactly
        # these tools, so there is no long tail to defer and no registry source
        # tags to partition by.
        {tools, ToolDisclosure.skipped_report(:custom_tools)}
    end
  end

  defp emit_disclosure_telemetry(report) do
    LemonCore.Telemetry.emit(
      [:coding_agent, :tool_disclosure, :applied],
      %{
        hidden_count: report.hidden_count,
        disclosed_count: report.disclosed_count,
        estimated_tokens: report.estimated_tokens
      },
      %{
        active: report.active,
        catalog_tier: report.catalog_tier,
        reason: report.reason
      }
    )
  end

  defp maybe_attach_wasm_status(report, nil), do: report
  defp maybe_attach_wasm_status(report, wasm_status), do: Map.put(report, :wasm, wasm_status)
end
