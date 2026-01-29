defmodule Ai.Providers.TextSanitizer do
  @moduledoc false

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
