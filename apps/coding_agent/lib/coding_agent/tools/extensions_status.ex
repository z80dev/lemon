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
      Get the extension status report for the current session.

      Returns information about:
      - Loaded extensions (name, version, capabilities, source path)
      - Extension load errors (syntax errors, compile errors)
      - Tool conflicts (which tools were shadowed and by what)

      Use this tool to diagnose plugin loading issues or understand which
      extensions and tools are active in the current session.
      """,
      label: "Extensions Status",
      parameters: %{
        "type" => "object",
        "properties" => %{
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
      include_details = Map.get(params, "include_details", false)
      get_status_report(session_id, include_details, cwd)
    end
  end

  @spec get_status_report(String.t(), boolean(), String.t()) ::
          AgentToolResult.t() | {:error, term()}
  defp get_status_report("", include_details, cwd) do
    # No session_id - fall back to listing all loaded extensions with tool conflicts
    extensions = CodingAgent.Extensions.list_extensions()
    tool_conflicts = CodingAgent.ToolRegistry.tool_conflict_report(cwd)

    output = format_fallback_report(extensions, tool_conflicts, include_details)

    %AgentToolResult{
      content: [%TextContent{text: output}],
      details: %{
        title: format_fallback_title(extensions, tool_conflicts, "no session context"),
        extensions: extensions,
        tool_conflicts: tool_conflicts
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

        output = format_fallback_report(extensions, tool_conflicts, include_details)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: %{
            title: format_fallback_title(extensions, tool_conflicts, "session not found"),
            extensions: extensions,
            tool_conflicts: tool_conflicts
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

  @spec format_fallback_report([map()], map(), boolean()) :: String.t()
  defp format_fallback_report(extensions, tool_conflicts, include_details) do
    sections = []

    # Summary section
    summary =
      "# Extension Status Report\n\n" <>
        "- **Extensions loaded:** #{length(extensions)}\n" <>
        "- **Total tools:** #{tool_conflicts.total_tools}\n"

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

    sections |> Enum.reverse() |> Enum.join("\n")
  end

  @spec format_fallback_title([map()], map(), String.t()) :: String.t()
  defp format_fallback_title(extensions, tool_conflicts, context) do
    ext_count = length(extensions)

    cond do
      tool_conflicts != nil and tool_conflicts.shadowed_count > 0 ->
        "#{ext_count} loaded, #{tool_conflicts.shadowed_count} conflicts (#{context})"

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
end
