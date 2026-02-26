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

  alias AgentCore.Types.AgentTool
  alias CodingAgent.Config
  alias CodingAgent.Extensions
  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolRegistry

  @type lifecycle_result :: %{
          extensions: [module()],
          hooks: keyword([function()]),
          tools: [AgentTool.t()],
          extension_status_report: Extensions.extension_status_report(),
          extension_paths: [String.t()],
          provider_registration: Extensions.provider_registration_report(),
          wasm_status: map() | nil
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

    tools =
      build_tools(
        cwd,
        tool_opts,
        extensions,
        custom_tools,
        extra_tools,
        tool_policy,
        approval_context
      )

    tool_conflict_report = ToolRegistry.tool_conflict_report(cwd, tool_opts)

    extension_status_report =
      Extensions.build_status_report(extensions, load_errors,
        cwd: cwd,
        tool_conflict_report: tool_conflict_report,
        provider_registration: provider_registration
      )
      |> maybe_attach_wasm_status(wasm_status)

    %{
      extensions: extensions,
      hooks: hooks,
      tools: tools,
      extension_status_report: extension_status_report,
      extension_paths: extension_paths,
      provider_registration: provider_registration,
      wasm_status: wasm_status
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

    tools = ToolRegistry.get_tools(cwd, tool_opts) ++ extra_tools
    tool_conflict_report = ToolRegistry.tool_conflict_report(cwd, tool_opts)

    extension_status_report =
      Extensions.build_status_report(extensions, load_errors,
        cwd: cwd,
        tool_conflict_report: tool_conflict_report,
        provider_registration: provider_registration
      )
      |> maybe_attach_wasm_status(wasm_status)

    %{
      extensions: extensions,
      hooks: hooks,
      tools: tools,
      extension_status_report: extension_status_report,
      extension_paths: extension_paths,
      provider_registration: provider_registration,
      wasm_status: wasm_status
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

    settings_paths ++
      [
        Config.extensions_dir(),
        Config.project_extensions_dir(cwd)
      ]
  end

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
          term()
        ) :: [AgentTool.t()]
  defp build_tools(
         cwd,
         tool_opts,
         extensions,
         custom_tools,
         extra_tools,
         tool_policy,
         approval_context
       ) do
    case custom_tools do
      nil ->
        ToolRegistry.get_tools(cwd, tool_opts) ++ extra_tools

      custom ->
        extension_tools = Extensions.get_tools(extensions, cwd)
        all_tools = custom ++ extension_tools ++ extra_tools

        if tool_policy && approval_context do
          ToolExecutor.wrap_all_with_approval(
            all_tools,
            tool_policy,
            approval_context
          )
        else
          all_tools
        end
    end
  end

  defp maybe_attach_wasm_status(report, nil), do: report
  defp maybe_attach_wasm_status(report, wasm_status), do: Map.put(report, :wasm, wasm_status)
end
