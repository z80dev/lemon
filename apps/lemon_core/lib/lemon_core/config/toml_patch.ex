defmodule LemonCore.Config.TomlPatch do
  @moduledoc """
  Minimal TOML patch helpers for targeted table key updates.

  The bundled TOML dependency supports decoding but not encoding, so this module
  performs focused textual edits while preserving unrelated config content.

  Table names are compared as TOML keys, not as text: `providers.openai-codex`
  matches a `[providers."openai-codex"]` header, so a patch never appends a
  second definition of a table that another writer spelled with quoted keys.
  """

  # A `[table]` header: the body is quoted segments or anything but brackets
  # and quotes, so `[a] # see [b]` and `[[array]]` are told apart correctly.
  @header_regex ~r/^\s*\[((?:"(?:[^"\\]|\\.)*"|'[^']*'|[^\[\]'"])+)\]\s*(?:#.*)?$/

  @spec upsert_string(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def upsert_string(content, table, key, value)
      when is_binary(content) and is_binary(table) and is_binary(key) and is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    upsert_raw_line(content, table, key, ~s(#{key} = "#{escaped}"))
  end

  @spec upsert_raw_line(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def upsert_raw_line(content, table, key, line)
      when is_binary(content) and is_binary(table) and is_binary(key) and is_binary(line) do
    content = normalize_newlines(content)

    case find_table_range(content, table) do
      {:ok, section_start, section_end} ->
        replace_section(content, section_start, section_end, fn section ->
          upsert_line_in_section(section, key, line)
        end)

      :error ->
        insert_table(content, table, line)
    end
  end

  # A table that is missing but has `[table.sub]` children goes in front of the
  # first child, so the parent is never defined after its own subtables.
  defp insert_table(content, table, line) do
    target = table_path!(table)
    block = "[#{table}]\n" <> line <> "\n"

    first_child =
      content
      |> line_offsets()
      |> Enum.find_value(fn {candidate, offset} ->
        case header_path(candidate) do
          {:ok, path} -> if List.starts_with?(path, target), do: offset
          :error -> nil
        end
      end)

    case first_child do
      nil ->
        prefix = ensure_trailing_newline(content)
        separator = if prefix == "", do: "", else: "\n"
        prefix <> separator <> block

      offset ->
        binary_part(content, 0, offset) <>
          block <> "\n" <> binary_part(content, offset, byte_size(content) - offset)
    end
  end

  @spec delete_key(String.t(), String.t(), String.t()) :: String.t()
  def delete_key(content, table, key)
      when is_binary(content) and is_binary(table) and is_binary(key) do
    content = normalize_newlines(content)

    case find_table_range(content, table) do
      {:ok, section_start, section_end} ->
        replace_section(content, section_start, section_end, fn section ->
          delete_line_from_section(section, key)
        end)

      :error ->
        content
    end
  end

  @doc """
  Delete a TOML table and every nested table below it.

  The edit is intentionally textual: content outside the selected table tree is
  returned byte-for-byte apart from newline normalization. This makes it safe
  for lifecycle commands to remove one managed object without re-encoding the
  rest of a user-owned config file or dropping unknown keys and comments.
  """
  @spec delete_table_tree(String.t(), String.t()) :: String.t()
  def delete_table_tree(content, table)
      when is_binary(content) and is_binary(table) do
    target = table_path!(table)

    content
    |> normalize_newlines()
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], false}, fn line, {kept, dropping?} ->
      case header_path(line) do
        {:ok, path} ->
          dropping? = List.starts_with?(path, target)
          if dropping?, do: {kept, true}, else: {[line | kept], false}

        :error ->
          if dropping?, do: {kept, true}, else: {[line | kept], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc """
  Parse a dotted TOML key (a table header body or a key) into its segments.

  Bare, basic-quoted and literal-quoted segments are supported, so
  `providers."openai-codex"` and `providers.openai-codex` both parse to
  `["providers", "openai-codex"]`.
  """
  @spec parse_dotted_key(String.t()) :: {:ok, [String.t()]} | :error
  def parse_dotted_key(raw) when is_binary(raw), do: parse_segments(String.trim(raw), [])

  @doc """
  Returns the parsed path of a standard `[table]` header line, or `:error` for
  any other line (including `[[array.of.tables]]` headers).
  """
  @spec header_path(String.t()) :: {:ok, [String.t()]} | :error
  def header_path(line) when is_binary(line) do
    case Regex.run(@header_regex, line, capture: :all_but_first) do
      [body] -> parse_dotted_key(body)
      _ -> :error
    end
  end

  defp parse_segments(raw, acc) do
    with {:ok, segment, rest} <- take_segment(raw) do
      case String.trim_leading(rest) do
        "" -> {:ok, Enum.reverse([segment | acc])}
        "." <> rest -> parse_segments(String.trim_leading(rest), [segment | acc])
        _ -> :error
      end
    end
  end

  defp take_segment(raw) do
    cond do
      match = Regex.run(~r/^"((?:[^"\\]|\\.)*)"/, raw) ->
        [whole, inner] = match
        {:ok, unescape_basic(inner), binary_part_after(raw, whole)}

      match = Regex.run(~r/^'([^']*)'/, raw) ->
        [whole, inner] = match
        {:ok, inner, binary_part_after(raw, whole)}

      match = Regex.run(~r/^[A-Za-z0-9_-]+/, raw) ->
        [whole] = match
        {:ok, whole, binary_part_after(raw, whole)}

      true ->
        :error
    end
  end

  defp binary_part_after(raw, prefix),
    do: binary_part(raw, byte_size(prefix), byte_size(raw) - byte_size(prefix))

  defp unescape_basic(value) do
    value
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp table_path!(table) do
    case parse_dotted_key(table) do
      {:ok, path} -> path
      :error -> raise ArgumentError, "invalid TOML table name: #{inspect(table)}"
    end
  end

  defp replace_section(content, section_start, section_end, fun) do
    section = binary_part(content, section_start, section_end - section_start)

    binary_part(content, 0, section_start) <>
      fun.(section) <>
      binary_part(content, section_end, byte_size(content) - section_end)
  end

  defp upsert_line_in_section(section, key, line) do
    key_regex = ~r/^\s*#{Regex.escape(key)}\s*=.*$/m

    case Regex.run(key_regex, section, return: :index) do
      [{offset, length}] ->
        tail_offset = offset + length

        binary_part(section, 0, offset) <>
          line <> binary_part(section, tail_offset, byte_size(section) - tail_offset)

      nil ->
        section = ensure_trailing_newline(section)
        section <> line <> "\n"
    end
  end

  defp delete_line_from_section(section, key) do
    key_regex = ~r/^\s*#{Regex.escape(key)}\s*=.*(?:\n|$)/m
    String.replace(section, key_regex, "")
  end

  # Byte offsets of the section body (after the header line) and of the next
  # table or array-of-tables header.
  defp find_table_range(content, table) do
    target = table_path!(table)
    lines = line_offsets(content)

    case Enum.find(lines, fn {line, _offset} -> header_path(line) == {:ok, target} end) do
      {line, offset} ->
        section_start = min(offset + byte_size(line) + 1, byte_size(content))

        section_end =
          Enum.find_value(lines, byte_size(content), fn {candidate, candidate_offset} ->
            if candidate_offset >= section_start and table_boundary?(candidate),
              do: candidate_offset
          end)

        {:ok, section_start, section_end}

      nil ->
        :error
    end
  end

  defp line_offsets(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.map_reduce(0, fn line, offset -> {{line, offset}, offset + byte_size(line) + 1} end)
    |> elem(0)
  end

  defp table_boundary?(line), do: Regex.match?(~r/^\s*\[.*\]\s*(?:#.*)?$/, line)

  defp normalize_newlines(content) do
    String.replace(content, "\r\n", "\n")
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
