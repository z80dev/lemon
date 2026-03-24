defmodule CodingAgent.Tools.FileFormatHelpers do
  @moduledoc """
  Shared helpers for BOM (byte order mark) handling and line ending
  detection/normalization across file-editing tools.
  """

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

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
end
