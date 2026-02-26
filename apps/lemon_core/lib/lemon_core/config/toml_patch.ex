defmodule LemonCore.Config.TomlPatch do
  @moduledoc """
  Minimal TOML patch helpers for targeted table key updates.

  The bundled TOML dependency supports decoding but not encoding, so this module
  performs focused textual edits while preserving unrelated config content.
  """

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
        section = String.slice(content, section_start, section_end - section_start)
        updated_section = upsert_line_in_section(section, key, line)

        String.slice(content, 0, section_start) <>
          updated_section <>
          String.slice(content, section_end, String.length(content) - section_end)

      :error ->
        prefix = ensure_trailing_newline(content)
        separator = if prefix == "", do: "", else: "\n"

        prefix <> separator <> "[#{table}]\n" <> line <> "\n"
    end
  end

  defp upsert_line_in_section(section, key, line) do
    key_regex = ~r/^\s*#{Regex.escape(key)}\s*=.*$/m

    if Regex.match?(key_regex, section) do
      String.replace(section, key_regex, line)
    else
      section = ensure_trailing_newline(section)
      section <> line <> "\n"
    end
  end

  defp find_table_range(content, table) do
    header_regex = ~r/^\s*\[#{Regex.escape(table)}\]\s*$/m

    case Regex.run(header_regex, content, return: :index) do
      [{header_pos, header_len}] ->
        header_end = header_pos + header_len
        section_start = skip_line_break(content, header_end)
        section_end = next_table_start(content, section_start)
        {:ok, section_start, section_end}

      _ ->
        :error
    end
  end

  defp skip_line_break(content, pos) do
    cond do
      String.slice(content, pos, 2) == "\r\n" -> pos + 2
      String.slice(content, pos, 1) == "\n" -> pos + 1
      true -> pos
    end
  end

  defp next_table_start(content, from) do
    remainder = String.slice(content, from, String.length(content) - from)

    case Regex.run(~r/^\s*\[[^\]]+\]\s*$/m, remainder, return: :index) do
      [{offset, _len}] -> from + offset
      _ -> String.length(content)
    end
  end

  defp normalize_newlines(content) do
    String.replace(content, "\r\n", "\n")
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
