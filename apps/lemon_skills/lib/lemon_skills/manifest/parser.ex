defmodule LemonSkills.Manifest.Parser do
  @moduledoc """
  Low-level frontmatter parser for skill manifest files.

  Handles YAML (`---`) and TOML (`+++`) frontmatter. Returns the raw parsed
  map and the remaining body string. Does not validate field semantics — see
  `LemonSkills.Manifest.Validator` for that.

  The parser is intentionally kept dependency-free: it uses a hand-rolled
  subset parser that covers the YAML used in practice by skill files. For
  correctness on exotic YAML syntax, add a proper library and replace this
  module without changing callers.
  """

  @type parse_result :: {:ok, map(), String.t()} | :error

  @doc """
  Parse raw skill file content.

  Returns `{:ok, manifest_map, body}` where `manifest_map` contains the
  parsed frontmatter fields (string keys) and `body` is the remaining
  markdown content with frontmatter stripped.

  Returns `:error` if frontmatter delimiters are present but malformed.
  Returns `{:ok, %{}, content}` when there is no frontmatter.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(content) when is_binary(content) do
    content = String.trim(content)

    cond do
      has_yaml_frontmatter?(content) -> parse_yaml_frontmatter(content)
      has_toml_frontmatter?(content) -> parse_toml_frontmatter(content)
      true -> {:ok, %{}, content}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp has_yaml_frontmatter?(content) do
    String.starts_with?(content, "---\n") or String.starts_with?(content, "---\r\n")
  end

  defp has_toml_frontmatter?(content) do
    String.starts_with?(content, "+++\n") or String.starts_with?(content, "+++\r\n")
  end

  defp parse_yaml_frontmatter(content) do
    # Strip leading ---
    rest =
      content
      |> String.trim_leading("---")
      |> ltrim_newline()

    cond do
      # Empty frontmatter: immediately followed by closing ---
      String.starts_with?(rest, "---\n") or String.starts_with?(rest, "---\r\n") ->
        body = rest |> String.trim_leading("---") |> String.trim()
        {:ok, %{}, body}

      # Frontmatter with no body (ends with ---)
      String.match?(rest, ~r/\r?\n---\s*$/) ->
        raw = String.replace(rest, ~r/\r?\n---\s*$/, "")
        {:ok, parse_yaml(raw), ""}

      # Normal: frontmatter then --- then body
      true ->
        case String.split(rest, ~r/\r?\n---\r?\n/, parts: 2) do
          [raw, body] -> {:ok, parse_yaml(raw), String.trim(body)}
          [_no_close] -> :error
        end
    end
  end

  defp parse_toml_frontmatter(content) do
    rest =
      content
      |> String.trim_leading("+++")
      |> ltrim_newline()

    case String.split(rest, ~r/\r?\n\+\+\+\r?\n/, parts: 2) do
      [raw, body] -> {:ok, parse_toml(raw), String.trim(body)}
      [_no_close] -> :error
    end
  end

  defp ltrim_newline(s) do
    s
    |> String.trim_leading("\r\n")
    |> String.trim_leading("\n")
  end

  # ---------------------------------------------------------------------------
  # YAML subset parser
  #
  # Handles:
  #   - key: value  (string values)
  #   - key:        (nested map start)
  #   - - item      (list item under a key)
  #   - # comments
  #
  # Two-level nesting is sufficient for the skill manifest schema.
  # ---------------------------------------------------------------------------

  defp parse_yaml(text) do
    text
    |> String.split(~r/\r?\n/)
    |> parse_yaml_lines(%{}, [], 0)
  end

  defp parse_yaml_lines([], acc, _ctx, _prev_indent), do: acc

  defp parse_yaml_lines([line | rest], acc, ctx, prev_indent) do
    trimmed = String.trim(line)
    indent = count_indent(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_yaml_lines(rest, acc, ctx, prev_indent)

      String.starts_with?(trimmed, "- ") ->
        value = String.trim_leading(trimmed, "- ")
        acc = add_list_item(acc, ctx, value)
        parse_yaml_lines(rest, acc, ctx, indent)

      String.contains?(line, ":") ->
        [raw_key | rest_parts] = String.split(String.trim(line), ":", parts: 2)
        key = String.trim(raw_key)
        value = rest_parts |> List.first("") |> String.trim()
        ctx = pop_context(ctx, indent)

        if value == "" do
          ctx = [{key, indent} | ctx]
          parse_yaml_lines(rest, acc, ctx, indent)
        else
          acc = put_nested(acc, ctx, key, parse_yaml_scalar(value))
          parse_yaml_lines(rest, acc, ctx, indent)
        end

      true ->
        parse_yaml_lines(rest, acc, ctx, prev_indent)
    end
  end

  defp count_indent(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 in [" ", "\t"]))
    |> length()
  end

  defp pop_context([], _indent), do: []

  defp pop_context([{_k, ci} | rest] = ctx, indent) do
    if ci >= indent, do: pop_context(rest, indent), else: ctx
  end

  defp put_nested(acc, [], key, value), do: Map.put(acc, key, value)

  defp put_nested(acc, ctx, key, value) do
    path = ctx |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    put_in_path(acc, path, key, value)
  end

  defp put_in_path(acc, [], key, value), do: Map.put(acc, key, value)

  defp put_in_path(acc, [h | t], key, value) do
    nested = Map.get(acc, h, %{})
    Map.put(acc, h, put_in_path(nested, t, key, value))
  end

  defp add_list_item(acc, [], _value), do: acc

  defp add_list_item(acc, ctx, value) do
    path = ctx |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    add_to_list_at_path(acc, path, value)
  end

  defp add_to_list_at_path(acc, [key], value) do
    existing = acc |> Map.get(key, []) |> ensure_list()
    Map.put(acc, key, existing ++ [value])
  end

  defp add_to_list_at_path(acc, [h | t], value) do
    nested = Map.get(acc, h, %{})
    Map.put(acc, h, add_to_list_at_path(nested, t, value))
  end

  defp ensure_list(v) when is_list(v), do: v
  defp ensure_list(_), do: []

  # Scalar coercion: booleans stay booleans, the rest become strings.
  defp parse_yaml_scalar("true"), do: true
  defp parse_yaml_scalar("false"), do: false
  defp parse_yaml_scalar(v), do: v

  # ---------------------------------------------------------------------------
  # TOML subset parser (flat key = value only)
  # ---------------------------------------------------------------------------

  defp parse_toml(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          acc

        String.contains?(trimmed, "=") ->
          case String.split(trimmed, "=", parts: 2) do
            [key, val] ->
              Map.put(acc, String.trim(key), parse_toml_value(String.trim(val)))

            _ ->
              acc
          end

        true ->
          acc
      end
    end)
  end

  defp parse_toml_value(v) do
    cond do
      String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
        String.slice(v, 1, String.length(v) - 2)

      String.starts_with?(v, "'") and String.ends_with?(v, "'") ->
        String.slice(v, 1, String.length(v) - 2)

      String.starts_with?(v, "[") and String.ends_with?(v, "]") ->
        v
        |> String.slice(1, String.length(v) - 2)
        |> String.split(",")
        |> Enum.map(fn item ->
          item |> String.trim() |> String.trim("\"") |> String.trim("'")
        end)

      v == "true" -> true
      v == "false" -> false
      String.match?(v, ~r/^\d+$/) -> String.to_integer(v)
      true -> v
    end
  end
end
