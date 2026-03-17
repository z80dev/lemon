defmodule LemonChannels.Adapters.WhatsApp.Formatter do
  @moduledoc """
  Converts Markdown to WhatsApp formatting.

  WhatsApp uses:
  - *bold* (not **bold**)
  - _italic_
  - ~strikethrough~ (not ~~strike~~)
  - ```code blocks``` (native)
  - `inline code` (native)
  """

  @doc "Converts markdown text to WhatsApp-compatible formatting."
  def format(text) when is_binary(text) do
    text
    |> split_code_blocks()
    |> Enum.map(fn
      {:code, block} -> block
      {:text, chunk} -> convert_markdown(chunk)
    end)
    |> Enum.join()
  end

  def format(nil), do: nil

  @doc "Removes unsupported markdown: links become plain text, images become [image: url]."
  def strip_unsupported(text) when is_binary(text) do
    text
    # Images: ![alt](url) → [image: url]
    |> String.replace(~r/!\[([^\]]*)\]\(([^)]+)\)/, "[image: \\2]")
    # Links: [text](url) → text
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
  end

  def strip_unsupported(nil), do: nil

  # Splits text into alternating {:text, ...} and {:code, ...} segments.
  # Code blocks (``` ... ```) are passed through unchanged.
  defp split_code_blocks(text) do
    # Split on ``` boundaries, preserving the delimiters
    parts = Regex.split(~r/(```[^`]*```)/s, text, include_captures: true)

    Enum.map(parts, fn part ->
      if String.starts_with?(part, "```") do
        {:code, part}
      else
        {:text, part}
      end
    end)
  end

  defp convert_markdown(text) do
    text
    # Protect inline code from further processing by splitting it out
    |> convert_with_inline_code()
  end

  defp convert_with_inline_code(text) do
    parts = Regex.split(~r/(`[^`]+`)/, text, include_captures: true)

    Enum.map_join(parts, fn part ->
      if String.starts_with?(part, "`") do
        part
      else
        part
        |> convert_bold()
        |> convert_strikethrough()
      end
    end)
  end

  # **bold** → *bold*
  defp convert_bold(text) do
    String.replace(text, ~r/\*\*([^*]+)\*\*/, "*\\1*")
  end

  # ~~strike~~ → ~strike~
  defp convert_strikethrough(text) do
    String.replace(text, ~r/~~([^~]+)~~/, "~\\1~")
  end
end
