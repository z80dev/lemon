defmodule Ai.Providers.TextSanitizer do
  @moduledoc """
  Sanitizes text for safe use with AI providers.

  Handles invalid or incomplete UTF-8 sequences by replacing them with the
  Unicode replacement character (U+FFFD), converts non-binary terms to strings,
  and normalizes nil input to an empty string.
  """

  @spec sanitize(binary() | nil | term()) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(text) when is_binary(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      {:error, valid, _rest} -> valid <> "\uFFFD"
      {:incomplete, valid, _rest} -> valid <> "\uFFFD"
      result when is_binary(result) -> result
    end
  end

  def sanitize(text), do: to_string(text)
end
