defmodule LemonCore.Rpc.ContentLength do
  @moduledoc "Content-Length JSON framing (8 MiB payload, 8 KiB header limits)."
  @behaviour LemonCore.Rpc.Framing
  @max_payload 8 * 1024 * 1024
  @max_header 8 * 1024

  @impl true
  def encode(message) do
    with {:ok, json} <- Jason.encode(message) do
      {:ok, "Content-Length: #{byte_size(json)}\r\n\r\n" <> json}
    end
  end

  @impl true
  def decode(buffer), do: decode_frames(buffer, [])

  defp decode_frames(buffer, acc) do
    case :binary.match(buffer, "\r\n\r\n") do
      {offset, 4} when offset <= @max_header ->
        <<header::binary-size(^offset), "\r\n\r\n", rest::binary>> = buffer

        with {:ok, length} <- content_length(header) do
          if byte_size(rest) < length do
            {:ok, Enum.reverse(acc), buffer}
          else
            <<body::binary-size(^length), remaining::binary>> = rest

            case Jason.decode(body) do
              {:ok, message} -> decode_frames(remaining, [message | acc])
              {:error, _} -> {:error, :invalid_json}
            end
          end
        end

      :nomatch when byte_size(buffer) <= @max_header ->
        {:ok, Enum.reverse(acc), buffer}

      _ ->
        {:error, :header_too_large}
    end
  end

  defp content_length(header) do
    lengths =
      header
      |> String.split("\r\n")
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "content-length", do: [String.trim(value)], else: []

          _ ->
            []
        end
      end)

    case lengths do
      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 and length <= @max_payload -> {:ok, length}
          _ -> {:error, :invalid_content_length}
        end

      _ ->
        {:error, :invalid_content_length}
    end
  end
end
