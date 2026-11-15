defmodule LemonCore.Rpc.JsonLines do
  @moduledoc "JSON line framing with an 8 MiB incomplete-frame limit."
  @behaviour LemonCore.Rpc.Framing
  @max_bytes 8 * 1024 * 1024

  @impl true
  def encode(message) do
    with {:ok, json} <- Jason.encode(message), do: {:ok, json <> "\n"}
  end

  @impl true
  def decode(buffer), do: decode_lines(buffer, [])

  defp decode_lines(buffer, acc) do
    case :binary.match(buffer, "\n") do
      {offset, 1} when offset <= @max_bytes ->
        <<line::binary-size(^offset), "\n", rest::binary>> = buffer

        case String.trim(line) do
          "" ->
            decode_lines(rest, acc)

          line ->
            case Jason.decode(line) do
              {:ok, message} -> decode_lines(rest, [message | acc])
              {:error, _} -> {:error, :invalid_json}
            end
        end

      :nomatch when byte_size(buffer) <= @max_bytes ->
        {:ok, Enum.reverse(acc), buffer}

      _ ->
        {:error, :frame_too_large}
    end
  end
end
