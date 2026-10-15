defmodule CodingAgent.Tools.FileFormatHelpers do
  @moduledoc """
  Shared helpers for BOM (byte order mark) handling and line ending
  detection/normalization across file-editing tools.
  """

  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  # Smart quotes and unicode dashes fold to ASCII for line-based matching.
  # Left/right single quote, single high-reversed-9 quote, prime, reversed prime
  @single_quotes [0x2018, 0x2019, 0x201B, 0x2032, 0x2035]
  # Left/right double quote, double low-9 / high-reversed-9 quote, (reversed) double prime
  @double_quotes [0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x2036]
  # En dash, em dash, horizontal bar, minus sign
  @dashes [0x2013, 0x2014, 0x2015, 0x2212]
  @horizontal_space [?\s, ?\t, ?\r, ?\f, ?\v, 0x00A0]

  @spec strip_bom(binary()) :: {binary() | nil, String.t()}
  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {@utf8_bom, rest}
  def strip_bom(content), do: {nil, content}

  @spec detect_line_ending(String.t()) :: String.t()
  def detect_line_ending(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  @spec normalize_to_lf(String.t()) :: String.t()
  def normalize_to_lf(text), do: String.replace(text, "\r\n", "\n")

  @spec restore_line_endings(String.t(), String.t()) :: String.t()
  def restore_line_endings(text, "\r\n") do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end

  def restore_line_endings(text, _), do: text

  @spec finalize_content(String.t(), String.t(), binary() | nil) :: binary()
  def finalize_content(content, line_ending, bom) do
    content_with_endings = restore_line_endings(content, line_ending)

    case bom do
      nil -> content_with_endings
      bom_bytes -> bom_bytes <> content_with_endings
    end
  end

  @doc "Normalize whitespace and typographic punctuation for tolerant line matching."
  def normalize_line(line) do
    line
    |> line_tokens()
    |> Enum.map_join(fn {text, _orig_start, _orig_end} -> text end)
  end

  # Tokens are `{normalized_text, orig_start, orig_end}` byte ranges of the
  # original line: one per codepoint (quotes/dashes folded to ASCII), with
  # whitespace runs collapsed to one " " token and trimmed at both ends.
  def line_tokens(line) do
    line
    |> tokenize(0, [])
    |> Enum.drop_while(&space_token?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&space_token?/1)
  end

  defp space_token?({" ", _start, _end}), do: true
  defp space_token?(_token), do: false

  defp tokenize(<<>>, _pos, acc), do: acc

  defp tokenize(<<cp::utf8, rest::binary>>, pos, acc) when cp in @horizontal_space do
    next = pos + byte_size(<<cp::utf8>>)

    case acc do
      [{" ", start, _end} | tail] -> tokenize(rest, next, [{" ", start, next} | tail])
      _ -> tokenize(rest, next, [{" ", pos, next} | acc])
    end
  end

  defp tokenize(<<cp::utf8, rest::binary>>, pos, acc) do
    next = pos + byte_size(<<cp::utf8>>)
    tokenize(rest, next, [{fold_codepoint(cp), pos, next} | acc])
  end

  # Invalid UTF-8 byte: keep it as an opaque one-byte token.
  defp tokenize(<<byte, rest::binary>>, pos, acc) do
    tokenize(rest, pos + 1, [{<<byte>>, pos, pos + 1} | acc])
  end

  defp fold_codepoint(cp) when cp in @single_quotes, do: "'"
  defp fold_codepoint(cp) when cp in @double_quotes, do: "\""
  defp fold_codepoint(cp) when cp in @dashes, do: "-"
  defp fold_codepoint(cp), do: <<cp::utf8>>
end
