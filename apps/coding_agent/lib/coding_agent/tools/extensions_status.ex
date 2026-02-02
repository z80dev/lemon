defmodule CodingAgent.Tools.ExtensionsStatus do
  @moduledoc """
  Extensions status tool for the coding agent.

  Returns the current extension status report for the running session,
  allowing the agent to self-diagnose plugin loading issues and conflicts.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @doc """
  Returns the ExtensionsStatus tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "")

    %AgentTool{
      name: "extensions_status",
      description: """
      Get the extension status report or reload extensions for the current session.

      Returns information about:
      - Loaded extensions (name, version, capabilities, source path)
      - Extension load errors (syntax errors, compile errors)
      - Tool conflicts (which tools were shadowed and by what)

      Use this tool to:
      - Diagnose plugin loading issues
      - Understand which extensions and tools are active
      - Reload extensions after adding, modifying, or removing extension files
      """,
      label: "Extensions Status",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "description" =>
              "Action to perform: 'status' to get the current report (default), 'reload' to re-discover and reload extensions.",
            "enum" => ["status", "reload"],
            "default" => "status"
          },
          "include_details" => %{
            "type" => "boolean",
            "description" =>
              "Include full details like source paths and config schemas. Defaults to false for a summary view.",
            "default" => false
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, session_id, cwd)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          session_id :: String.t(),
          cwd :: String.t()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, session_id, cwd) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      action = Map.get(params, "action", "status")
      include_details = Map.get(params, "include_details", false)

      case action do
        "reload" ->
          reload_extensions(session_id, include_details, cwd)

        _ ->
          get_status_report(session_id, include_details, cwd)
      end
    end
  end

  @spec get_status_report(String.t(), boolean(), String.t()) ::
          AgentToolResult.t() | {:error, term()}
  defp get_status_report("", include_details, cwd) do
    # No session_id - fall back to listing all loaded extensions with tool conflicts
    extensions = CodingAgent.Extensions.list_extensions()
    tool_conflicts = CodingAgent.ToolRegistry.tool_conflict_report(cwd)
    {load_errors, loaded_at} = CodingAgent.Extensions.last_load_errors()

    output = format_fallback_report(extensions, tool_conflicts, load_errors, loaded_at, include_details)

    %AgentToolResult{
      content: [%TextContent{text: output}],
      details: %{
        title: format_fallback_title(extensions, tool_conflicts, load_errors, "no session context"),
        extensions: extensions,
        tool_conflicts: tool_conflicts,
        load_errors: load_errors,
        loaded_at: loaded_at
      }
    }
  end

  defp get_status_report(session_id, include_details, cwd) do
    # Try to get the session from the registry
    case get_session_pid(session_id) do
      {:ok, session_pid} ->
        report = CodingAgent.Session.get_extension_status_report(session_pid)
        format_report(report, include_details)

      {:error, :not_found} ->
        # Fall back to listing all loaded extensions with tool conflicts
        extensions = CodingAgent.Extensions.list_extensions()
        tool_conflicts = CodingAgent.ToolRegistry.tool_conflict_report(cwd)
        {load_errors, loaded_at} = CodingAgent.Extensions.last_load_errors()

        output = format_fallback_report(extensions, tool_conflicts, load_errors, loaded_at, include_details)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: %{
            title: format_fallback_title(extensions, tool_conflicts, load_errors, "session not found"),
            extensions: extensions,
            tool_conflicts: tool_conflicts,
            load_errors: load_errors,
            loaded_at: loaded_at
          }
        }
    end
  end

  @spec get_session_pid(String.t()) :: {:ok, pid()} | {:error, :not_found}
  defp get_session_pid(session_id) do
    case Process.whereis(CodingAgent.SessionRegistry) do
      nil ->
        {:error, :not_found}

      _pid ->
        case Registry.lookup(CodingAgent.SessionRegistry, session_id) do
          [{pid, _value}] -> {:ok, pid}
          [] -> {:error, :not_found}
        end
    end
  end

  @spec reload_extensions(String.t(), boolean(), String.t()) ::
          AgentToolResult.t() | {:error, term()}
  defp reload_extensions("", _include_details, _cwd) do
    {:error,
     "Cannot reload extensions: no session context available.\n\n" <>
       "The reload action requires an active session to update the tool registry."}
  end

  defp reload_extensions(session_id, include_details, _cwd) do
    case get_session_pid(session_id) do
      {:ok, session_pid} ->
        case CodingAgent.Session.reload_extensions(session_pid) do
          {:ok, report} ->
            format_reload_report(report, include_details)

          {:error, :already_streaming} ->
            {:error,
             "Cannot reload extensions while the session is streaming.\n\n" <>
               "Please wait for the current operation to complete and try again."}
        end

      {:error, :not_found} ->
        {:error,
         "Cannot reload extensions: session not found.\n\n" <>
           "The session may have been terminated or the ID is invalid."}
    end
  end

  @spec format_reload_report(map(), boolean()) :: AgentToolResult.t()
  defp format_reload_report(report, include_details) do
    sections = []

    # Summary section with reload indicator
    summary =
      "# Extensions Reloaded\n\n" <>
        "- **Extensions loaded:** #{report.total_loaded}\n" <>
        "- **Load errors:** #{report.total_errors}\n" <>
        "- **Reloaded at:** #{format_timestamp(report.loaded_at)}\n"

    sections = [summary | sections]

    # Extensions section
    sections =
      if report.total_loaded > 0 do
        ext_section = format_extensions_section(report.extensions, include_details)
        [ext_section | sections]
      else
        sections
      end

    # Load errors section
    sections =
      if report.total_errors > 0 do
        error_section = format_errors_section(report.load_errors)
        [error_section | sections]
      else
        sections
      end

    # Tool conflicts section
    sections =
      if report.tool_conflicts != nil do
        conflict_section = format_conflicts_section(report.tool_conflicts)
        [conflict_section | sections]
      else
        sections
      end

    output = sections |> Enum.reverse() |> Enum.join("\n")

    title =
      cond do
        report.total_errors > 0 ->
          "Reloaded: #{report.total_loaded} loaded, #{report.total_errors} errors"

        report.tool_conflicts != nil and report.tool_conflicts.shadowed_count > 0 ->
          "Reloaded: #{report.total_loaded} loaded, #{report.tool_conflicts.shadowed_count} conflicts"

        true ->
          "Reloaded: #{report.total_loaded} extensions"
      end

    %AgentToolResult{
      content: [%TextContent{text: output}],
      details: %{
        title: title,
        action: "reload",
        total_loaded: report.total_loaded,
        total_errors: report.total_errors,
        tool_conflicts: report.tool_conflicts
      }
    }
  end

  @spec format_report(map() | nil, boolean()) :: AgentToolResult.t()
  defp format_report(nil, _include_details) do
    %AgentToolResult{
      content: [%TextContent{text: "No extension status report available."}],
      details: %{title: "No report"}
    }
  end

  defp format_report(report, include_details) do
    sections = []

    # Summary section
    summary =
      "# Extension Status Report\n\n" <>
        "- **Extensions loaded:** #{report.total_loaded}\n" <>
        "- **Load errors:** #{report.total_errors}\n" <>
        "- **Loaded at:** #{format_timestamp(report.loaded_at)}\n"

    sections = [summary | sections]

    # Extensions section
    sections =
      if report.total_loaded > 0 do
        ext_section = format_extensions_section(report.extensions, include_details)
        [ext_section | sections]
      else
        sections
      end

    # Load errors section
    sections =
      if report.total_errors > 0 do
        error_section = format_errors_section(report.load_errors)
        [error_section | sections]
      else
        sections
      end

    # Tool conflicts section
    sections =
      if report.tool_conflicts != nil do
        conflict_section = format_conflicts_section(report.tool_conflicts)
        [conflict_section | sections]
      else
        sections
      end

    output = sections |> Enum.reverse() |> Enum.join("\n")

    title =
      cond do
        report.total_errors > 0 ->
          "#{report.total_loaded} loaded, #{report.total_errors} errors"

        report.tool_conflicts != nil and report.tool_conflicts.shadowed_count > 0 ->
          "#{report.total_loaded} loaded, #{report.tool_conflicts.shadowed_count} conflicts"

        true ->
          "#{report.total_loaded} extensions loaded"
      end

    %AgentToolResult{
      content: [%TextContent{text: output}],
      details: %{
        title: title,
        total_loaded: report.total_loaded,
        total_errors: report.total_errors,
        tool_conflicts: report.tool_conflicts
      }
    }
  end

  @spec format_extensions_section([map()], boolean()) :: String.t()
  defp format_extensions_section(extensions, include_details) do
    header = "\n## Loaded Extensions\n"

    ext_list =
      Enum.map(extensions, fn ext ->
        base = "- **#{ext.name}** v#{ext.version}"

        capabilities =
          if ext.capabilities != [] do
            " (#{Enum.join(ext.capabilities, ", ")})"
          else
            ""
          end

        details =
          if include_details do
            source =
              if ext.source_path do
                "\n  - Source: `#{ext.source_path}`"
              else
                ""
              end

            module = "\n  - Module: `#{inspect(ext.module)}`"

            config_schema =
              if ext.config_schema != %{} do
                "\n  - Has config schema: yes"
              else
                ""
              end

            source <> module <> config_schema
          else
            ""
          end

        base <> capabilities <> details
      end)

    header <> Enum.join(ext_list, "\n")
  end

  @spec format_errors_section([map()]) :: String.t()
  defp format_errors_section(errors) do
    header = "\n## Load Errors\n"

    error_list =
      Enum.map(errors, fn error ->
        "- `#{error.source_path}`\n  - #{error.error_message}"
      end)

    header <> Enum.join(error_list, "\n")
  end

  @spec format_conflicts_section(map()) :: String.t()
  defp format_conflicts_section(conflicts) do
    header =
      "\n## Tool Registry\n" <>
        "- **Total tools:** #{conflicts.total_tools}\n" <>
        "- **Built-in:** #{conflicts.builtin_count}\n" <>
        "- **From extensions:** #{conflicts.extension_count}\n" <>
        "- **Shadowed:** #{conflicts.shadowed_count}\n"

    if conflicts.conflicts != [] do
      conflict_details =
        "\n### Conflicts\n" <>
          (conflicts.conflicts
           |> Enum.map(fn c ->
             winner =
               case c.winner do
                 :builtin -> "built-in"
                 {:extension, mod} -> "extension `#{inspect(mod)}`"
               end

             shadowed =
               c.shadowed
               |> Enum.map(fn {:extension, mod} -> "`#{inspect(mod)}`" end)
               |> Enum.join(", ")

             "- **#{c.tool_name}**: winner is #{winner}, shadowed: #{shadowed}"
           end)
           |> Enum.join("\n"))

      header <> conflict_details
    else
      header
    end
  end

  @spec format_fallback_report([map()], map(), [map()], integer() | nil, boolean()) :: String.t()
  defp format_fallback_report(extensions, tool_conflicts, load_errors, loaded_at, include_details) do
    sections = []

    # Summary section
    summary =
      "# Extension Status Report\n\n" <>
        "- **Extensions loaded:** #{length(extensions)}\n" <>
        "- **Load errors:** #{length(load_errors)}\n" <>
        "- **Total tools:** #{tool_conflicts.total_tools}\n" <>
        format_loaded_at(loaded_at)

    sections = [summary | sections]

    # Extensions section
    sections =
      if extensions != [] do
        ext_section = format_extensions_section(extensions, include_details)
        [ext_section | sections]
      else
        sections
      end

    # Tool conflicts section
    sections =
      if tool_conflicts != nil do
        conflict_section = format_conflicts_section(tool_conflicts)
        [conflict_section | sections]
      else
        sections
      end

    sections =
      if load_errors != [] do
        error_section = format_errors_section(load_errors)
        [error_section | sections]
      else
        sections
      end

    sections |> Enum.reverse() |> Enum.join("\n")
  end

  @spec format_fallback_title([map()], map(), [map()], String.t()) :: String.t()
  defp format_fallback_title(extensions, tool_conflicts, load_errors, context) do
    ext_count = length(extensions)
    error_count = length(load_errors)
    conflict_count = if tool_conflicts, do: tool_conflicts.shadowed_count, else: 0

    cond do
      error_count > 0 and conflict_count > 0 ->
        "#{ext_count} loaded, #{error_count} errors, #{conflict_count} conflicts (#{context})"

      error_count > 0 ->
        "#{ext_count} loaded, #{error_count} errors (#{context})"

      conflict_count > 0 ->
        "#{ext_count} loaded, #{conflict_count} conflicts (#{context})"

      true ->
        "#{ext_count} extensions loaded (#{context})"
    end
  end

  @spec format_timestamp(integer()) :: String.t()
  defp format_timestamp(ms) when is_integer(ms) do
    datetime = DateTime.from_unix!(div(ms, 1000))
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_timestamp(_), do: "unknown"

  defp format_loaded_at(nil), do: ""

  defp format_loaded_at(ms) when is_integer(ms) do
    "- **Last load:** #{format_timestamp(ms)}\n"
  end
end
