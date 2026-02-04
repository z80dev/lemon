defmodule LemonSkills.Tools.ReadSkill do
  @moduledoc """
  Tool for agents to fetch skill details.

  This tool allows agents to look up skill information including:
  - Skill metadata (name, description)
  - Full skill content
  - Status and requirements

  ## Usage

  The tool is designed to be used by coding agents to load relevant
  skills into their context when needed.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonSkills.{Registry, Entry, Status}

  @doc """
  Returns the ReadSkill tool definition.

  ## Options

  - `:cwd` - Working directory for project skill lookup
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)

    %AgentTool{
      name: "read_skill",
      description: """
      Read details about an available skill. Use this to fetch skill content \
      and instructions when you need guidance on a specific topic or workflow.
      """,
      label: "Read Skill",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" => "The skill key/identifier to look up"
          },
          "include_status" => %{
            "type" => "boolean",
            "description" => "Include status information (requirements check)"
          }
        },
        "required" => ["key"]
      },
      execute: &execute(&1, &2, &3, &4, cwd)
    }
  end

  @doc """
  Execute the read_skill tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "key" and optional "include_status"
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused)
  - `cwd` - Current working directory
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          cwd :: String.t() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd) do
    key = Map.get(params, "key", "")
    include_status = Map.get(params, "include_status", false)

    opts = if cwd, do: [cwd: cwd], else: []

    case Registry.get(key, opts) do
      {:ok, entry} ->
        build_result(entry, include_status, opts)

      :error ->
        build_not_found_result(key, opts)
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_result(%Entry{} = entry, include_status, opts) do
    # Get skill content
    content_text =
      case Entry.content(entry) do
        {:ok, content} -> content
        {:error, _} -> "(Content not available)"
      end

    # Build response
    parts = [
      "# Skill: #{entry.name}",
      "",
      "**Key:** #{entry.key}",
      "**Description:** #{entry.description}",
      "**Source:** #{format_source(entry.source)}",
      "**Path:** #{entry.path}",
      ""
    ]

    parts =
      if include_status do
        status = Status.check_entry(entry, opts)

        status_parts = [
          "## Status",
          "",
          "**Ready:** #{status.ready}",
          if(status.disabled, do: "**Disabled:** true", else: nil),
          if(status.missing_bins != [],
            do: "**Missing binaries:** #{Enum.join(status.missing_bins, ", ")}",
            else: nil
          ),
          if(status.missing_config != [],
            do: "**Missing config:** #{Enum.join(status.missing_config, ", ")}",
            else: nil
          ),
          ""
        ]

        parts ++ Enum.reject(status_parts, &is_nil/1)
      else
        parts
      end

    parts =
      parts ++
        [
          "## Content",
          "",
          content_text
        ]

    text = Enum.join(parts, "\n")

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        key: entry.key,
        name: entry.name,
        path: entry.path
      }
    }
  end

  defp build_not_found_result(key, opts) do
    # List available skills as suggestions
    available = Registry.list(opts)

    suggestions =
      if available == [] do
        "No skills are currently available."
      else
        skill_list =
          available
          |> Enum.map(fn entry -> "- #{entry.key}: #{entry.description}" end)
          |> Enum.join("\n")

        "Available skills:\n#{skill_list}"
      end

    text = """
    Skill not found: #{key}

    #{suggestions}
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        error: "not_found",
        key: key
      }
    }
  end

  defp format_source(:global), do: "Global (~/.lemon/agent/skill)"
  defp format_source(:project), do: "Project (.lemon/skill)"
  defp format_source(url) when is_binary(url), do: url
  defp format_source(other), do: inspect(other)
end
