defmodule CodingAgent.Tools.Bash.StreamingPreview do
  @moduledoc """
  Bounded replacement snapshots for sanitized Bash streaming output.

  Keeps the most recent 50,000 bytes by default. Truncation occurs on a UTF-8
  boundary and copies the retained tail so a small preview cannot keep a large
  source binary alive. The fixed omission marker is outside the payload budget.

  This bounds the streaming accumulator only. The executor remains responsible
  for final output and spill files; this is not mailbox or Port backpressure.
  """

  @default_max_bytes 50_000
  @omission_marker "[Earlier output omitted from streaming preview]\n"

  defstruct text: "", max_bytes: @default_max_bytes, truncated: false

  @type t :: %__MODULE__{
          text: String.t(),
          max_bytes: pos_integer(),
          truncated: boolean()
        }

  @spec new(pos_integer()) :: t()
  def new(max_bytes \\ @default_max_bytes)

  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    %__MODULE__{max_bytes: max_bytes}
  end

  def new(_max_bytes), do: raise(ArgumentError, "preview byte limit must be positive")

  @doc "Append a sanitized, valid UTF-8 chunk without retaining its discarded bytes."
  @spec append(t(), String.t()) :: t()
  def append(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    chunk_bytes = byte_size(chunk)
    truncated = state.truncated or byte_size(state.text) + chunk_bytes > state.max_bytes

    text =
      if chunk_bytes >= state.max_bytes do
        tail(chunk, state.max_bytes)
      else
        tail(state.text, state.max_bytes - chunk_bytes) <> chunk
      end

    %{state | text: text, truncated: truncated}
  end

  @spec render(t()) :: String.t()
  def render(%__MODULE__{truncated: true, text: text}), do: @omission_marker <> text
  def render(%__MODULE__{text: text}), do: text

  defp tail(text, max_bytes) do
    offset = max(byte_size(text) - max_bytes, 0)

    text
    |> binary_part(offset, byte_size(text) - offset)
    |> trim_continuation_bytes()
    |> :binary.copy()
  end

  defp trim_continuation_bytes(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: trim_continuation_bytes(rest)

  defp trim_continuation_bytes(text), do: text
end
