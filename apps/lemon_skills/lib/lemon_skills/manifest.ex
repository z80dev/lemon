defmodule LemonSkills.Manifest do
  @moduledoc """
  Manifest parsing for skill files.

  Handles parsing of SKILL.md files which can have:
  - YAML frontmatter (recommended)
  - No frontmatter (just markdown content)

  ## Frontmatter Format

  Skills should have a SKILL.md file with YAML frontmatter:

      ---
      name: bun-file-io
      description: Use this when working on file operations
      requires:
        bins:
          - bun
        config:
          - BUN_PATH
      ---

      ## When to use

      - Editing file I/O code
      - Handling directory operations

  ## Manifest Fields

  - `name` - Skill identifier (defaults to directory name)
  - `description` - Brief description for relevance matching
  - `requires` - Dependencies and requirements
    - `bins` - Required binaries (checked with `which`)
    - `config` - Required configuration/environment variables
  - `tags` - Tags for categorization
  - `version` - Skill version
  - `author` - Skill author
  """

  @type manifest :: %{String.t() => any()}

  @doc """
  Parse skill content with optional frontmatter.

  Returns the parsed manifest and the body content.

  ## Parameters

  - `content` - The raw file content

  ## Returns

  - `{:ok, manifest, body}` - Parsed manifest and remaining content
  - `:error` - If parsing fails

  ## Examples

      {:ok, manifest, body} = LemonSkills.Manifest.parse(content)
      manifest["name"]  # => "bun-file-io"
  """
  @spec parse(String.t()) :: {:ok, manifest(), String.t()} | :error
  def parse(content) when is_binary(content) do
    content = String.trim(content)

    cond do
      has_yaml_frontmatter?(content) ->
        parse_with_frontmatter(content)

      has_toml_frontmatter?(content) ->
        parse_with_toml_frontmatter(content)

      true ->
        # No frontmatter - return empty manifest with full content as body
        {:ok, %{}, content}
    end
  end

  @doc """
  Parse only the frontmatter, returning just the manifest.

  ## Parameters

  - `content` - The raw file content

  ## Returns

  - `{:ok, manifest}` - Parsed manifest
  - `:error` - If parsing fails
  """
  @spec parse_frontmatter(String.t()) :: {:ok, manifest()} | :error
  def parse_frontmatter(content) do
    case parse(content) do
      {:ok, manifest, _body} -> {:ok, manifest}
      :error -> :error
    end
  end

  @doc """
  Parse only the body content, stripping frontmatter.

  ## Parameters

  - `content` - The raw file content

  ## Returns

  The body content with frontmatter removed.
  """
  @spec parse_body(String.t()) :: String.t()
  def parse_body(content) do
    case parse(content) do
      {:ok, _manifest, body} -> body
      :error -> content
    end
  end

  @doc """
  Validate a manifest has required fields.

  ## Parameters

  - `manifest` - The parsed manifest

  ## Returns

  - `:ok` - Manifest is valid
  - `{:error, reason}` - Validation failed
  """
  @spec validate(manifest()) :: :ok | {:error, String.t()}
  def validate(manifest) when is_map(manifest) do
    # Currently no required fields, but we validate structure
    cond do
      not is_nil(manifest["requires"]) and not is_map(manifest["requires"]) ->
        {:error, "requires must be a map"}

      not is_nil(manifest["tags"]) and not is_list(manifest["tags"]) ->
        {:error, "tags must be a list"}

      true ->
        :ok
    end
  end

  @doc """
  Get required binaries from manifest.

  ## Parameters

  - `manifest` - The parsed manifest

  ## Returns

  List of required binary names.
  """
  @spec required_bins(manifest()) :: [String.t()]
  def required_bins(manifest) do
    requires = Map.get(manifest, "requires", %{})
    bins = Map.get(requires, "bins", [])
    ensure_list(bins)
  end

  @doc """
  Get required configuration from manifest.

  ## Parameters

  - `manifest` - The parsed manifest

  ## Returns

  List of required config keys/environment variables.
  """
  @spec required_config(manifest()) :: [String.t()]
  def required_config(manifest) do
    requires = Map.get(manifest, "requires", %{})
    config = Map.get(requires, "config", [])
    ensure_list(config)
  end

  defp ensure_list(val) when is_list(val), do: val
  defp ensure_list(_), do: []

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp has_yaml_frontmatter?(content) do
    String.starts_with?(content, "---\n") or String.starts_with?(content, "---\r\n")
  end

  defp has_toml_frontmatter?(content) do
    String.starts_with?(content, "+++\n") or String.starts_with?(content, "+++\r\n")
  end

  defp parse_with_frontmatter(content) do
    # Remove leading ---
    content = String.trim_leading(content, "---")
    content = String.trim_leading(content, "\r\n")
    content = String.trim_leading(content, "\n")

    # Handle case where frontmatter is followed by --- with optional trailing content
    cond do
      # Empty frontmatter: starts immediately with closing ---
      String.starts_with?(content, "---\n") or String.starts_with?(content, "---\r\n") ->
        body = content |> String.trim_leading("---") |> String.trim()
        {:ok, %{}, body}

      # Frontmatter ends with --- at end of content (no body)
      String.match?(content, ~r/\r?\n---\s*$/) ->
        frontmatter_raw = String.replace(content, ~r/\r?\n---\s*$/, "")
        manifest = parse_yaml_simple(frontmatter_raw)
        {:ok, manifest, ""}

      # Normal case: frontmatter followed by --- and body
      true ->
        case String.split(content, ~r/\r?\n---\r?\n/, parts: 2) do
          [frontmatter_raw, body] ->
            manifest = parse_yaml_simple(frontmatter_raw)
            {:ok, manifest, String.trim(body)}

          [_no_closing] ->
            # No closing ---, treat as error
            :error
        end
    end
  end

  defp parse_with_toml_frontmatter(content) do
    # Remove leading +++
    content = String.trim_leading(content, "+++")
    content = String.trim_leading(content, "\r\n")
    content = String.trim_leading(content, "\n")

    case String.split(content, ~r/\r?\n\+\+\+\r?\n/, parts: 2) do
      [frontmatter_raw, body] ->
        manifest = parse_toml_simple(frontmatter_raw)
        {:ok, manifest, String.trim(body)}

      [_no_closing] ->
        :error
    end
  end

  # Simple YAML parser for frontmatter
  # Handles basic key: value pairs and nested structures up to 2 levels deep
  defp parse_yaml_simple(yaml_text) do
    lines = String.split(yaml_text, ~r/\r?\n/)
    parse_yaml_lines(lines, %{}, [], 0)
  end

  # Context is a list of {key, indent_level} for nested structures
  defp parse_yaml_lines([], acc, _context, _prev_indent), do: acc

  defp parse_yaml_lines([line | rest], acc, context, prev_indent) do
    trimmed = String.trim(line)
    indent = count_indent(line)

    cond do
      # Empty line or comment
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_yaml_lines(rest, acc, context, prev_indent)

      # List item
      String.starts_with?(trimmed, "- ") ->
        value = String.trim_leading(trimmed, "- ")
        acc = add_list_item(acc, context, value, indent)
        parse_yaml_lines(rest, acc, context, indent)

      # Key: value pair
      String.contains?(line, ":") ->
        case String.split(String.trim(line), ":", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)

            # Pop context items that are at same or higher indent level
            context = pop_context(context, indent)

            if value == "" do
              # Key with no inline value - start nested content
              context = [{key, indent} | context]
              parse_yaml_lines(rest, acc, context, indent)
            else
              acc = put_nested(acc, context, key, value)
              parse_yaml_lines(rest, acc, context, indent)
            end

          _ ->
            parse_yaml_lines(rest, acc, context, prev_indent)
        end

      true ->
        parse_yaml_lines(rest, acc, context, prev_indent)
    end
  end

  defp count_indent(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " " or &1 == "\t"))
    |> length()
  end

  # Pop context items that are at same or deeper indent level than current
  defp pop_context([], _indent), do: []

  defp pop_context([{_key, ctx_indent} | rest] = context, indent) do
    if ctx_indent >= indent do
      pop_context(rest, indent)
    else
      context
    end
  end

  # Put a value at a nested path determined by context
  defp put_nested(acc, [], key, value) do
    Map.put(acc, key, value)
  end

  defp put_nested(acc, context, key, value) do
    path = context |> Enum.reverse() |> Enum.map(fn {k, _} -> k end)
    put_in_path(acc, path, key, value)
  end

  defp put_in_path(acc, [], key, value) do
    Map.put(acc, key, value)
  end

  defp put_in_path(acc, [h | t], key, value) do
    nested = Map.get(acc, h, %{})
    nested = put_in_path(nested, t, key, value)
    Map.put(acc, h, nested)
  end

  # Add a list item at a nested path
  defp add_list_item(acc, [], value, _indent) do
    # This shouldn't happen in well-formed YAML, but handle it
    existing = Map.get(acc, "_items", [])
    Map.put(acc, "_items", existing ++ [value])
  end

  defp add_list_item(acc, context, value, _indent) do
    path = context |> Enum.reverse() |> Enum.map(fn {k, _} -> k end)
    add_to_list_at_path(acc, path, value)
  end

  defp add_to_list_at_path(acc, [key], value) do
    existing = Map.get(acc, key, [])
    existing = if is_list(existing), do: existing, else: []
    Map.put(acc, key, existing ++ [value])
  end

  defp add_to_list_at_path(acc, [h | t], value) do
    nested = Map.get(acc, h, %{})
    nested = add_to_list_at_path(nested, t, value)
    Map.put(acc, h, nested)
  end

  # Simple TOML parser - just key = value pairs
  defp parse_toml_simple(toml_text) do
    toml_text
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          acc

        String.contains?(trimmed, "=") ->
          case String.split(trimmed, "=", parts: 2) do
            [key, value] ->
              key = String.trim(key)
              value = value |> String.trim() |> parse_toml_value()
              Map.put(acc, key, value)

            _ ->
              acc
          end

        true ->
          acc
      end
    end)
  end

  defp parse_toml_value(value) do
    cond do
      # Quoted string
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim("'")

      # Array
      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        value
        |> String.trim("[")
        |> String.trim("]")
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))

      # Boolean
      value == "true" ->
        true

      value == "false" ->
        false

      # Number
      String.match?(value, ~r/^\d+$/) ->
        String.to_integer(value)

      true ->
        value
    end
  end
end
