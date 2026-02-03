defmodule LemonGateway.Telegram.Formatter do
  @moduledoc """
  Formats text for Telegram MarkdownV2 while preserving resume lines.
  """

  # Characters that must be escaped in MarkdownV2
  @escape_chars ["_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!"]

  @doc """
  Escapes text for Telegram MarkdownV2 format.
  Preserves resume lines (lines starting with specific patterns like session IDs).
  """
  @spec escape_markdown(String.t()) :: String.t()
  def escape_markdown(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&escape_line/1)
    |> Enum.join("\n")
  end

  def escape_markdown(nil), do: ""

  defp escape_line(line) do
    # Don't escape resume lines (they contain session IDs that should stay as-is)
    if resume_line?(line) do
      line
    else
      escape_chars(line)
    end
  end

  defp resume_line?(line) do
    # Resume lines typically look like: `/resume claude:abc123` or similar
    String.starts_with?(String.trim(line), "/resume")
  end

  defp escape_chars(text) do
    Enum.reduce(@escape_chars, text, fn char, acc ->
      String.replace(acc, char, "\\#{char}")
    end)
  end

  @doc """
  Prepares text for sending to Telegram with MarkdownV2 parse mode.
  Returns {text, parse_mode} tuple.
  """
  @spec prepare_for_telegram(String.t()) :: {String.t(), String.t()}
  def prepare_for_telegram(text) do
    {escape_markdown(text), "MarkdownV2"}
  end
end
