defmodule LemonSkills.Manifest.Parser do
  @moduledoc """
  Low-level frontmatter parser for skill manifest files.

  Handles YAML (`---`) and TOML (`+++`) frontmatter. Returns the raw parsed
  map and the remaining body string. Does not validate field semantics — see
  `LemonSkills.Manifest.Validator` for that.

  YAML is parsed through `YamlElixir`, while TOML uses the small flat subset
  historically supported by Lemon skill manifests.
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

        case parse_yaml(raw) do
          {:ok, manifest} -> {:ok, manifest, ""}
          :error -> :error
        end

      # Normal: frontmatter then --- then body
      true ->
        case String.split(rest, ~r/\r?\n---\r?\n/, parts: 2) do
          [raw, body] ->
            case parse_yaml(raw) do
              {:ok, manifest} -> {:ok, manifest, String.trim(body)}
              :error -> :error
            end

          [_no_close] ->
            :error
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
  # YAML parser
  # ---------------------------------------------------------------------------

  defp parse_yaml(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      _ -> :error
    end
  end

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

      v == "true" ->
        true

      v == "false" ->
        false

      String.match?(v, ~r/^\d+$/) ->
        String.to_integer(v)

      true ->
        v
    end
  end
end
