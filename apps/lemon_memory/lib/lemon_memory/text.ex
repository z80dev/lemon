defmodule LemonMemory.Text do
  @moduledoc false

  @spec clip_bytes(String.t() | nil, non_neg_integer()) :: String.t()
  def clip_bytes(nil, _bytes), do: ""
  def clip_bytes(text, bytes) when byte_size(text) <= bytes, do: text
  def clip_bytes(text, bytes), do: binary_part(text, 0, boundary(text, bytes))

  # Session-search previews preserve whole graphemes, not just codepoints.
  @spec clip_bytes(String.t() | nil, non_neg_integer(), :grapheme) :: String.t()
  def clip_bytes(nil, _bytes, :grapheme), do: ""
  def clip_bytes(text, bytes, :grapheme) when byte_size(text) <= bytes, do: text

  def clip_bytes(text, bytes, :grapheme) do
    binary_part(text, 0, grapheme_boundary(text, bytes, 0))
  end

  @spec boundary(binary(), non_neg_integer()) :: non_neg_integer()
  def boundary(text, position) when position > 0 do
    if String.valid?(binary_part(text, 0, position)),
      do: position,
      else: boundary(text, position - 1)
  end

  def boundary(_text, 0), do: 0

  defp grapheme_boundary(text, bytes, position) do
    case String.next_grapheme(text) do
      {grapheme, rest} when byte_size(grapheme) <= bytes ->
        size = byte_size(grapheme)
        grapheme_boundary(rest, bytes - size, position + size)

      _ ->
        position
    end
  end
end
