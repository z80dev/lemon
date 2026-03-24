defmodule Ai.Providers.SSEParser do
  @moduledoc """
  Shared SSE (Server-Sent Events) stream parser for OpenAI-compatible providers.
  """

  @doc """
  Parses an SSE chunk buffer into decoded JSON events and any remaining incomplete data.

  Returns `{events, incomplete}` where `events` is a list of decoded JSON maps
  and `incomplete` is the trailing partial data that should be prepended to the next chunk.
  """
  def parse_sse_chunk(buffer) do
    parts = String.split(buffer, "\n\n")

    {complete_parts, [incomplete]} =
      if length(parts) > 1 do
        Enum.split(parts, -1)
      else
        {[], parts}
      end

    events =
      complete_parts
      |> Enum.flat_map(fn part ->
        part
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(&String.trim_leading(&1, "data:"))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" || &1 == "[DONE]"))
        |> Enum.flat_map(fn data ->
          case Jason.decode(data) do
            {:ok, event} -> [event]
            _ -> []
          end
        end)
      end)

    {events, incomplete}
  end
end
