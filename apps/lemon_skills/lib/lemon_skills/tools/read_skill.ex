defmodule LemonSkills.Tools.ReadSkill do
  @moduledoc """
  Tool for agents to fetch skill details.

  This tool allows agents to look up skill information including:
  - Skill metadata (name, description, activation state)
  - Full skill content or targeted partial loads
  - Status and requirements
  - Parsed manifest data
  - Referenced supplementary files

  ## Views

  - `"full"` — (default) full SKILL.md content + header metadata
  - `"summary"` — metadata and activation state only; no body
  - `"section"` — a specific markdown heading section from the body
  - `"file"` — a referenced file by relative path within the skill directory

  ## Usage

  The tool is designed to be used by coding agents to load relevant
  skills into their context when needed.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonSkills.{Registry, Entry, Manifest, PathBoundary, SkillView}

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
      and instructions when you need guidance on a specific topic or workflow.\
      """,
      label: "Read Skill",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" => "The skill key/identifier to look up"
          },
          "view" => %{
            "type" => "string",
            "enum" => ["full", "summary", "section", "file"],
            "description" =>
              "What to return: 'full' (default) = full SKILL.md, 'summary' = metadata only, " <>
                "'section' = specific heading section (requires 'section'), " <>
                "'file' = a referenced file (requires 'path')"
          },
          "section" => %{
            "type" => "string",
            "description" => "Heading name to extract (used with view='section')"
          },
          "path" => %{
            "type" => "string",
            "description" => "Relative file path within skill directory (used with view='file')"
          },
          "include_status" => %{
            "type" => "boolean",
            "description" => "Include status information (requirements check)"
          },
          "include_manifest" => %{
            "type" => "boolean",
            "description" => "Include parsed manifest fields as structured data"
          },
          "max_chars" => %{
            "type" => "integer",
            "description" => "Truncate body content to at most this many characters"
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
  - `params` - Parameters map with "key" and optional fields
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
    view = Map.get(params, "view", "full")
    section = Map.get(params, "section")
    file_path = Map.get(params, "path")
    include_status = Map.get(params, "include_status", false)
    include_manifest = Map.get(params, "include_manifest", false)
    max_chars = Map.get(params, "max_chars")

    opts = if cwd, do: [cwd: cwd], else: []

    view_opts = %{
      view: view,
      section: section,
      path: file_path,
      include_status: include_status,
      include_manifest: include_manifest,
      max_chars: max_chars
    }

    case Registry.get(key, opts) do
      {:ok, entry} ->
        build_result(entry, view_opts, opts)

      :error ->
        build_not_found_result(key, opts)
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_result(%Entry{} = entry, view_opts, opts) do
    parts = build_header(entry)

    parts =
      if view_opts.include_status do
        parts ++ build_status_section(entry, opts)
      else
        parts
      end

    parts =
      if view_opts.include_manifest do
        parts ++ build_manifest_section(entry)
      else
        parts
      end

    parts = parts ++ build_content_section(entry, view_opts)

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

  defp build_header(%Entry{} = entry) do
    skill_view = SkillView.from_entry(entry)

    [
      "# Skill: #{entry.name}",
      "",
      "**Key:** #{entry.key}",
      "**Description:** #{entry.description}",
      "**Source:** #{format_source(entry.source)}",
      "**Path:** #{entry.path}",
      "**Activation:** #{skill_view.activation_state}",
      ""
    ]
  end

  defp build_status_section(%Entry{} = entry, opts) do
    alias LemonSkills.Status

    status = Status.check_entry(entry, opts)

    lines = [
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
      if(status.missing_env_vars != [],
        do: "**Missing env vars:** #{Enum.join(status.missing_env_vars, ", ")}",
        else: nil
      ),
      if(status.missing_tools != [],
        do: "**Missing tools:** #{Enum.join(status.missing_tools, ", ")}",
        else: nil
      ),
      ""
    ]

    Enum.reject(lines, &is_nil/1)
  end

  defp build_manifest_section(%Entry{manifest: nil}), do: []

  defp build_manifest_section(%Entry{manifest: manifest}) do
    platforms = Manifest.platforms(manifest)
    bins = Manifest.required_bins(manifest)
    env_vars = Manifest.required_environment_variables(manifest)
    tools = Manifest.requires_tools(manifest)
    refs = Manifest.references(manifest)

    fields =
      [
        if(platforms != ["any"], do: "- platforms: #{Enum.join(platforms, ", ")}"),
        if(bins != [], do: "- required_bins: #{Enum.join(bins, ", ")}"),
        if(env_vars != [], do: "- required_env_vars: #{Enum.join(env_vars, ", ")}"),
        if(tools != [], do: "- requires_tools: #{Enum.join(tools, ", ")}"),
        if(refs != [], do: "- references: #{length(refs)} file(s)")
      ]
      |> Enum.reject(&is_nil/1)

    if fields == [] do
      []
    else
      ["## Manifest", "" | fields] ++ [""]
    end
  end

  defp build_content_section(_entry, %{view: "summary"}), do: []

  defp build_content_section(entry, %{view: "full", max_chars: max_chars}) do
    content_text =
      case Entry.content(entry) do
        {:ok, content} -> maybe_truncate(content, max_chars)
        {:error, _} -> "(Content not available)"
      end

    ["## Content", "", content_text]
  end

  defp build_content_section(entry, %{view: "section", section: section_name, max_chars: max_chars}) do
    content_text =
      case Entry.content(entry) do
        {:ok, content} ->
          body = Manifest.parse_body(content)
          extract_section(body, section_name) |> maybe_truncate(max_chars)

        {:error, _} ->
          "(Content not available)"
      end

    ["## Section: #{section_name || "(none)"}", "", content_text]
  end

  defp build_content_section(entry, %{view: "file", path: file_path, max_chars: max_chars}) do
    content_text = load_referenced_file(entry, file_path) |> maybe_truncate(max_chars)
    ["## File: #{file_path || "(none)"}", "", content_text]
  end

  defp build_content_section(entry, view_opts) do
    # Fallback to full for unknown view values
    build_content_section(entry, %{view_opts | view: "full"})
  end

  defp extract_section(_body, nil) do
    "No section specified. Use the 'section' parameter to name a heading."
  end

  defp extract_section(body, section_name) do
    lines = String.split(body, "\n")
    heading_re = ~r/^##+\s+#{Regex.escape(section_name)}\s*$/i

    case Enum.find_index(lines, &Regex.match?(heading_re, &1)) do
      nil ->
        "Section '#{section_name}' not found in skill content."

      start_idx ->
        rest = Enum.drop(lines, start_idx)

        # Find the next heading at any level (##, ###, etc.) after the first line
        end_idx =
          rest
          |> Enum.drop(1)
          |> Enum.find_index(&Regex.match?(~r/^##/, &1))

        section_lines =
          if end_idx do
            Enum.take(rest, end_idx + 1)
          else
            rest
          end

        Enum.join(section_lines, "\n")
    end
  end

  defp load_referenced_file(_entry, nil) do
    "No path specified. Use the 'path' parameter to specify a file path relative to the skill directory."
  end

  defp load_referenced_file(%Entry{path: skill_path}, rel_path) do
    full_path = Path.join(skill_path, rel_path)

    # Safety: ensure the resolved path is still under the skill directory
    expanded = Path.expand(full_path)
    expanded_skill = Path.expand(skill_path)

    if PathBoundary.within?(expanded_skill, expanded) do
      case File.read(expanded) do
        {:ok, content} -> content
        {:error, reason} -> "Could not read '#{rel_path}': #{:file.format_error(reason)}"
      end
    else
      "Path '#{rel_path}' is outside the skill directory."
    end
  end

  defp maybe_truncate(content, nil), do: content

  defp maybe_truncate(content, max_chars) when is_integer(max_chars) and max_chars > 0 do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <> "\n... (truncated at #{max_chars} chars)"
    else
      content
    end
  end

  defp maybe_truncate(content, _), do: content

  defp build_not_found_result(key, opts) do
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
