defmodule CodingAgent.Debug.Protocol do
  @moduledoc """
  Debug Adapter Protocol framing policy over `LemonCore.Rpc`.

  Encoding uses the shared Content-Length framer. Decoding retains DAP's
  tolerant stdout policy: malformed frames are skipped and non-protocol bytes
  are returned as diagnostics rather than closing the adapter connection.
  `decode/1` returns `{messages, remainder, junk}` for standalone consumers.
  `Framing` adapts this policy to the shared RPC client's incremental buffer;
  diagnostic bytes arrive as `{:rpc_message, {:diagnostic, bytes}}`.
  """

  alias LemonCore.Rpc.ContentLength

  @headers ["Content-Length:", "content-length:", "CONTENT-LENGTH:"]
  @header_terminator "\r\n\r\n"
  @max_body_bytes 64 * 1024 * 1024
  @max_header_bytes 4096

  @type message :: map()

  @doc "Encode one DAP message (request/response/event map) as framed iodata."
  @spec encode(map()) :: iodata()
  def encode(message) when is_map(message) do
    {:ok, framed} = ContentLength.encode(message)
    framed
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
        keep =
          header_prefix_size(buffer, min(byte_size(buffer), byte_size("Content-Length:") - 1))

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
    case :binary.match(buffer, @headers) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  defp header_prefix_size(_buffer, 0), do: 0

  defp header_prefix_size(buffer, size) do
    tail = binary_part(buffer, byte_size(buffer) - size, size)

    if Enum.any?(@headers, &(binary_part(&1, 0, size) == tail)),
      do: size,
      else: header_prefix_size(buffer, size - 1)
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

  defmodule Framing do
    @moduledoc """
    Shared RPC framing callbacks with DAP's tolerant diagnostic handling.

    The RPC engine owns the incomplete buffer. Complete non-protocol text is
    delivered to the debug client as a diagnostic, never as a DAP response.
    """

    @behaviour LemonCore.Rpc.Framing

    @impl true
    def encode(message), do: LemonCore.Rpc.ContentLength.encode(message)

    @impl true
    def decode(buffer) do
      {messages, rest, junk} = CodingAgent.Debug.Protocol.decode(buffer)
      messages = if junk == "", do: messages, else: [{:diagnostic, junk} | messages]
      {:ok, messages, rest}
    end
  end
end
