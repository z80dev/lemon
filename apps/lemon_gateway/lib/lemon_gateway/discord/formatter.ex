defmodule LemonGateway.Discord.Formatter do
  @moduledoc false

  @discord_message_limit 2_000

  @spec chunk_text(String.t() | nil, pos_integer()) :: [String.t()]
  def chunk_text(text, limit \\ @discord_message_limit)

  def chunk_text(nil, _limit), do: []

  def chunk_text(text, limit) when is_binary(text) and limit > 0 do
    text
    |> String.trim()
    |> do_chunk(limit, [])
    |> Enum.reverse()
  end

  @spec format_error(term()) :: String.t()
  def format_error(error) do
    "❌ " <> to_string(error)
  end

  @spec tool_call_embed(map()) :: map()
  def tool_call_embed(tool_call) when is_map(tool_call) do
    name = Map.get(tool_call, :name) || Map.get(tool_call, "name") || "tool"
    status = Map.get(tool_call, :status) || Map.get(tool_call, "status") || "running"
    detail = Map.get(tool_call, :detail) || Map.get(tool_call, "detail") || ""

    %{
      title: "Tool Call: #{name}",
      description: to_string(detail),
      color: embed_color(status),
      footer: %{text: "status: #{status}"}
    }
  end

  defp do_chunk("", _limit, acc), do: acc

  defp do_chunk(text, limit, acc) when byte_size(text) <= limit, do: [text | acc]

  defp do_chunk(text, limit, acc) do
    split_at =
      text
      |> String.slice(0, limit)
      |> split_position()

    head = String.slice(text, 0, split_at)
    tail = String.slice(text, split_at, byte_size(text) - split_at)

    do_chunk(String.trim_leading(tail), limit, [head | acc])
  end

  defp split_position(chunk) do
    case :binary.matches(chunk, ["\n", " "]) do
      [] ->
        byte_size(chunk)

      matches ->
        {idx, _len} = List.last(matches)
        if idx < 1, do: byte_size(chunk), else: idx
    end
  end

  defp embed_color("ok"), do: 0x57F287
  defp embed_color("done"), do: 0x57F287
  defp embed_color("error"), do: 0xED4245
  defp embed_color(_), do: 0x5865F2
end
