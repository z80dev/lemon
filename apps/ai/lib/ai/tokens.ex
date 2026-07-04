defmodule Ai.Tokens do
  @moduledoc """
  Fast token estimation helpers.

  These functions centralize Lemon's rough 4-units-per-token heuristic. It is
  useful for thresholds, diagnostics, and fallback estimates, but it is not a
  tokenizer and will differ from model-specific token counts.

  Use `estimate_chars/1` when the caller is budgeting user-visible text by
  Unicode character count. Use `estimate_bytes/1` when the existing boundary is
  payload bytes, serialized data, or transport size.
  """

  @chars_per_token 4
  @bytes_per_token 4

  @doc """
  Estimates tokens from Unicode character count using the 4 chars/token heuristic.
  """
  @spec estimate_chars(String.t()) :: non_neg_integer()
  def estimate_chars(text) when is_binary(text) do
    text
    |> String.length()
    |> estimate_char_count()
  end

  @doc """
  Estimates tokens from byte size using the 4 bytes/token heuristic.
  """
  @spec estimate_bytes(binary()) :: non_neg_integer()
  def estimate_bytes(binary) when is_binary(binary) do
    binary
    |> byte_size()
    |> estimate_byte_count()
  end

  @doc """
  Estimates tokens from a precomputed Unicode character count.
  """
  @spec estimate_char_count(non_neg_integer()) :: non_neg_integer()
  def estimate_char_count(count) when is_integer(count) and count >= 0 do
    div(count, @chars_per_token)
  end

  @doc """
  Estimates tokens from a precomputed byte count.
  """
  @spec estimate_byte_count(non_neg_integer()) :: non_neg_integer()
  def estimate_byte_count(count) when is_integer(count) and count >= 0 do
    div(count, @bytes_per_token)
  end
end
