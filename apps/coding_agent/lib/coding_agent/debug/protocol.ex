defmodule CodingAgent.Debug.Protocol do
  @moduledoc """
  Debug Adapter Protocol wire framing.

  DAP messages are JSON bodies preceded by a `Content-Length` header block
  terminated by `\\r\\n\\r\\n` (the same framing as LSP). `decode/1` drains every
  complete message from a buffer and returns the unparsed remainder. Bytes that
  precede a header block (an adapter printing to stdout/stderr) are returned
  separately as `junk` so callers can surface them as adapter diagnostics
  instead of stalling on them.
  """

  @header_terminator "\r\n\r\n"
  @max_body_bytes 64 * 1024 * 1024
  @max_header_bytes 4096

  @type message :: map()

  @doc "Encode one DAP message (request/response/event map) as framed iodata."
  @spec encode(map()) :: iodata()
  def encode(message) when is_map(message) do
    body = Jason.encode!(message)
    ["Content-Length: ", Integer.to_string(byte_size(body)), @header_terminator, body]
  end

  @doc """
  Decode every complete message in `buffer`.

  Returns `{messages, rest, junk}` where `messages` are decoded maps in arrival
  order (malformed JSON bodies are skipped), `rest` is the incomplete tail to
  prepend to the next chunk and `junk` is non-protocol text that was dropped.
  """
  @spec decode(binary()) :: {[message()], binary(), binary()}
  def decode(buffer) when is_binary(buffer), do: decode(buffer, [], [])

  defp decode(buffer, messages, junk) do
    case header_start(buffer) do
      nil ->
        # Keep a short tail in case it is the start of a split header.
        keep = min(byte_size(buffer), byte_size("Content-Length:") - 1)
        {dropped, tail} = :erlang.split_binary(buffer, byte_size(buffer) - keep)
        finish(messages, tail, [junk, dropped])

      start ->
        {dropped, framed} = :erlang.split_binary(buffer, start)

        case parse_frame(framed) do
          {:ok, body, rest} ->
            messages =
              case Jason.decode(body) do
                {:ok, %{} = message} -> [message | messages]
                _ -> messages
              end

            decode(rest, messages, [junk, dropped])

          :incomplete ->
            finish(messages, framed, [junk, dropped])

          {:invalid, rest} ->
            # A header block without a usable Content-Length: drop it and resync.
            decode(rest, messages, [junk, dropped])
        end
    end
  end

  defp finish(messages, rest, junk) do
    {Enum.reverse(messages), rest, IO.iodata_to_binary(junk)}
  end

  defp header_start(buffer) do
    case :binary.match(buffer, ["Content-Length:", "content-length:", "CONTENT-LENGTH:"]) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  defp parse_frame(framed) do
    case :binary.match(framed, @header_terminator) do
      :nomatch ->
        if byte_size(framed) > @max_header_bytes,
          do: {:invalid, binary_part(framed, 1, byte_size(framed) - 1)},
          else: :incomplete

      {index, length} ->
        header = binary_part(framed, 0, index)
        rest = binary_part(framed, index + length, byte_size(framed) - index - length)

        case content_length(header) do
          {:ok, size} when byte_size(rest) >= size ->
            <<body::binary-size(^size), rest::binary>> = rest
            {:ok, body, rest}

          {:ok, _size} ->
            :incomplete

          :error ->
            {:invalid, rest}
        end
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(value)) do
              {size, ""} when size >= 0 and size <= @max_body_bytes -> {:ok, size}
              _ -> :error
            end
          end

        _ ->
          nil
      end
    end)
  end
end
