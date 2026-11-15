defmodule LemonMCP.Framing.Stdio do
  @moduledoc """
  MCP JSON-line framing for stdio streams that merge stderr into stdout.

  Non-protocol lines are discarded without logging their contents. Complete and
  incomplete frames are bounded at 8 MiB; only JSON-RPC 2.0 maps reach the client.
  The transport sends and receives bytes without adding or removing framing.
  """
  @behaviour LemonCore.Rpc.Framing

  alias LemonMCP.Protocol

  @max_bytes 8 * 1024 * 1024

  @impl true
  def encode(message) do
    encoded = if is_struct(message), do: Protocol.encode(message), else: Jason.encode(message)

    case encoded do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  @impl true
  def decode(buffer), do: decode_lines(buffer, [])

  defp decode_lines(buffer, messages) do
    case :binary.match(buffer, "\n") do
      {offset, 1} when offset <= @max_bytes ->
        <<line::binary-size(^offset), "\n", rest::binary>> = buffer

        case Jason.decode(line) do
          {:ok, %{"jsonrpc" => "2.0"} = message} ->
            decode_lines(rest, [message | messages])

          _ ->
            decode_lines(rest, messages)
        end

      :nomatch when byte_size(buffer) <= @max_bytes ->
        {:ok, Enum.reverse(messages), buffer}

      _ ->
        {:error, :frame_too_large}
    end
  end
end
