defmodule CodingAgent.Tools.ExtensionsStatus do
  @moduledoc """
  Read-only extension status tool for the coding agent.

  Returns the running session's extension status report so the agent can
  self-diagnose plugin loading issues and tool conflicts. Without a live session
  (no session id, or one no longer registered) it reports the node's loaded
  extensions, last load errors and the tool conflicts for its cwd instead.
  Reloading extensions is an operator action, not a tool action: a model turn
  always runs while the session is streaming, which refuses reloads.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

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

      Use this tool to diagnose plugin loading issues and to understand which
      extensions and tools are active.
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
      include_details = Map.get(params, "include_details", false) == true

      case session_report(session_id) do
        {:ok, nil} ->
          %AgentToolResult{
            content: [%TextContent{text: "No extension status report available."}],
            details: %{title: "No report"}
          }

        {:ok, report} ->
          render(report, include_details, nil)

        {:fallback, context} ->
          render(fallback_report(cwd), include_details, context)
      end
    end
  end

  defp session_report(""), do: {:fallback, "no session context"}

  defp session_report(session_id) do
    with pid when is_pid(pid) <- Process.whereis(CodingAgent.SessionRegistry),
         [{session_pid, _value}] <- Registry.lookup(CodingAgent.SessionRegistry, session_id) do
      {:ok, CodingAgent.Session.get_extension_status_report(session_pid)}
    else
      _ -> {:fallback, "session not found"}
    end
  end

  defp fallback_report(cwd) do
    extensions = CodingAgent.Extensions.list_extensions()
    {load_errors, loaded_at} = CodingAgent.Extensions.last_load_errors()

    %{
      extensions: extensions,
      load_errors: load_errors,
      loaded_at: loaded_at,
      total_loaded: length(extensions),
      total_errors: length(load_errors),
      tool_conflicts: CodingAgent.ToolRegistry.tool_conflict_report(cwd)
    }
  end

  # `context` is nil for a live session report, or why the node-wide fallback
  # was used instead.
  defp render(report, include_details, context) do
    sections =
      [
        summary(report, context),
        if(report.total_loaded > 0,
          do: format_extensions_section(report.extensions, include_details)
        ),
        if(report.total_errors > 0, do: format_errors_section(report.load_errors)),
        if(report.tool_conflicts, do: format_conflicts_section(report.tool_conflicts)),
        case report[:tool_disclosure] do
          disclosure when is_map(disclosure) ->
            format_tool_disclosure_section(disclosure, include_details)

          _ ->
            nil
        end
      ]
      |> Enum.reject(&is_nil/1)

    details =
      if context do
        Map.take(report, [:extensions, :tool_conflicts, :load_errors, :loaded_at])
      else
        report
        |> Map.take([:total_loaded, :total_errors, :tool_conflicts])
        |> Map.put(:tool_disclosure, report[:tool_disclosure])
      end

    %AgentToolResult{
      content: [%TextContent{text: Enum.join(sections, "\n")}],
      details: Map.put(details, :title, title(report, context))
    }
  end

  defp summary(report, context) do
    total_tools =
      if context && report.tool_conflicts,
        do: "- **Total tools:** #{report.tool_conflicts.total_tools}\n",
        else: ""

    "# Extension Status Report\n\n" <>
      "- **Extensions loaded:** #{report.total_loaded}\n" <>
      "- **Load errors:** #{report.total_errors}\n" <>
      total_tools <> format_loaded_at(report.loaded_at)
  end

  defp title(report, context) do
    conflicts = if report.tool_conflicts, do: report.tool_conflicts.shadowed_count, else: 0

    counts =
      [
        "#{report.total_loaded} " <>
          if(report.total_errors > 0 or conflicts > 0,
            do: "loaded",
            else: "extensions loaded"
          ),
        if(report.total_errors > 0, do: "#{report.total_errors} errors"),
        if(conflicts > 0, do: "#{conflicts} conflicts")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    if context, do: "#{counts} (#{context})", else: counts
  end

  @doc """
  Render the tool-disclosure section of a status report.

  Public so the section can be exercised directly; `report[:tool_disclosure]`
  is absent from reports produced before disclosure existed, and callers must
  keep working when it is.
  """
  @spec format_tool_disclosure_section(map(), boolean()) :: String.t()
  def format_tool_disclosure_section(disclosure, include_details \\ false) do
    header = "\n## Tool Disclosure\n" <> identity_lines(disclosure)

    tokens =
      "- **Estimated schema tokens:** #{Map.get(disclosure, :estimated_tokens, 0)} " <>
        "(budget #{Map.get(disclosure, :budget_tokens, 0)})"

    if Map.get(disclosure, :active, false) do
      hidden_names = Map.get(disclosure, :hidden_names, [])

      base =
        "- **Active:** true\n" <>
          tokens <>
          exposed_tokens(disclosure) <>
          "\n- **Disclosed tools:** #{Map.get(disclosure, :disclosed_count, 0)} · " <>
          "**Hidden tools:** #{Map.get(disclosure, :hidden_count, 0)}\n" <>
          "- **Catalog tier:** #{Map.get(disclosure, :catalog_tier, :inactive)}\n"

      details =
        if include_details and hidden_names != [],
          do: disclosed_names(disclosure) <> "- **Hidden:** #{Enum.join(hidden_names, ", ")}\n",
          else: ""

      shadowed =
        case Map.get(disclosure, :shadowed_by_bridge, []) do
          [] -> ""
          names -> "- **Dropped (bridge name collision):** #{Enum.join(names, ", ")}\n"
        end

      header <> base <> details <> shadowed
    else
      reason = Map.get(disclosure, :reason) || "inactive"
      header <> "- **Active:** false (#{reason})\n" <> tokens <> "\n"
    end
  end

  defp identity_lines(disclosure) do
    profile =
      case Map.get(disclosure, :profile) do
        nil -> ""
        profile -> "- **Profile:** #{profile}\n"
      end

    digest =
      case Map.get(disclosure, :catalog_digest) do
        digest when is_binary(digest) -> "- **Catalog digest:** #{digest}\n"
        _ -> ""
      end

    profile <> digest
  end

  defp exposed_tokens(disclosure) do
    case Map.get(disclosure, :disclosed_tokens) do
      tokens when is_integer(tokens) -> " · **Exposed after disclosure:** #{tokens}"
      _ -> ""
    end
  end

  defp disclosed_names(disclosure) do
    case Map.get(disclosure, :disclosed_names, []) do
      [] -> ""
      names -> "- **Disclosed:** #{Enum.join(names, ", ")}\n"
    end
  end

  defp format_extensions_section(extensions, include_details) do
    lines =
      Enum.map(extensions, fn ext ->
        capabilities =
          if ext.capabilities != [], do: " (#{Enum.join(ext.capabilities, ", ")})", else: ""

        details =
          if include_details do
            source = if ext.source_path, do: "\n  - Source: `#{ext.source_path}`", else: ""
            schema = if ext.config_schema != %{}, do: "\n  - Has config schema: yes", else: ""
            source <> "\n  - Module: `#{inspect(ext.module)}`" <> schema
          else
            ""
          end

        "- **#{ext.name}** v#{ext.version}" <> capabilities <> details
      end)

    "\n## Loaded Extensions\n" <> Enum.join(lines, "\n")
  end

  defp format_errors_section(errors) do
    lines = Enum.map(errors, &"- `#{&1.source_path}`\n  - #{&1.error_message}")
    "\n## Load Errors\n" <> Enum.join(lines, "\n")
  end

  defp format_conflicts_section(conflicts) do
    header =
      "\n## Tool Registry\n" <>
        "- **Total tools:** #{conflicts.total_tools}\n" <>
        "- **Built-in:** #{conflicts.builtin_count}\n" <>
        "- **From extensions:** #{conflicts.extension_count}\n" <>
        "- **Shadowed:** #{conflicts.shadowed_count}\n"

    if conflicts.conflicts == [] do
      header
    else
      header <>
        "\n### Conflicts\n" <> Enum.map_join(conflicts.conflicts, "\n", &format_conflict/1)
    end
  end

  defp format_conflict(conflict) do
    winner =
      case conflict.winner do
        :builtin -> "built-in"
        {:extension, mod} -> "extension `#{inspect(mod)}`"
      end

    shadowed =
      Enum.map_join(conflict.shadowed, ", ", fn
        {:extension, mod} -> "`#{inspect(mod)}`"
      end)

    "- **#{conflict.tool_name}**: winner is #{winner}, shadowed: #{shadowed}"
  end

  defp format_loaded_at(ms) when is_integer(ms) do
    timestamp =
      ms |> div(1000) |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    "- **Loaded at:** #{timestamp}\n"
  end

  defp format_loaded_at(_), do: ""
end
