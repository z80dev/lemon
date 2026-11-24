defmodule LemonAi.Providers.SSEParser do
  @moduledoc """
  Incremental Server-Sent Events decoder shared by the provider transports.

  `parse_sse_chunk/1` takes the carried-over buffer with the next body chunk
  appended and returns the complete events plus the remainder to carry into
  the next call. A JSON event split across transport frames is therefore
  decoded once it is complete, never dropped.

  Events are dispatched at the blank line ending them, as the SSE format
  requires, and also as soon as their accumulated `data` already forms a
  complete JSON object: OpenAI-compatible servers often separate events with
  a single newline. Multi-line `data` fields are joined with `"\\n"`. Comments,
  `event`, `id` and `retry` fields are ignored.

  Items are decoded JSON objects, `:done` for the `[DONE]` sentinel, or a
  final `{:stream_error, details}` for an event that is complete but not a JSON
  object. Malformed events fail the stream rather than being skipped: a lost
  event can drop text, a tool call or the terminal stop reason.
  """

  require Logger

  @type item :: map() | :done | {:stream_error, LemonAi.Error.parsed_error()}

  @doc """
  Parses an SSE buffer into complete items and the remainder to carry forward.

  Append `"\\n\\n"` to the remainder at end of input to flush a final event
  that was not terminated by a blank line.
  """
  @spec parse_sse_chunk(binary()) :: {[item()], binary()}
  def parse_sse_chunk(buffer) when is_binary(buffer) do
    {lines, [incomplete]} = buffer |> :binary.split("\n", [:global]) |> Enum.split(-1)
    {items, pending} = Enum.reduce(lines, {[], []}, &parse_line/2)

    case items |> Enum.reverse() |> Enum.split_while(&(not match?({:stream_error, _}, &1))) do
      {items, []} -> {items, carry(pending) <> incomplete}
      {items, [error | _]} -> {items ++ [error], ""}
    end
  end

  defp parse_line(line, {items, pending}) do
    case String.trim_trailing(line, "\r") do
      "" ->
        {dispatch(pending, items), []}

      ":" <> _comment ->
        {items, pending}

      "data:" <> value ->
        pending = [String.replace_prefix(value, " ", "") | pending]

        case decode(pending) do
          {:ok, item} -> {[item | items], []}
          :incomplete -> {items, pending}
        end

      _other_field ->
        {items, pending}
    end
  end

  defp dispatch([], items), do: items

  defp dispatch(pending, items) do
    case decode(pending) do
      {:ok, item} ->
        [item | items]

      :incomplete ->
        if Enum.all?(pending, &(&1 == "")) do
          items
        else
          size = pending |> Enum.map(&byte_size/1) |> Enum.sum()
          Logger.warning("Provider stream sent a malformed event (#{size} bytes)")
          [{:stream_error, LemonAi.Providers.StreamTransport.malformed_event()} | items]
        end
    end
  end

  defp decode(pending) do
    case pending |> Enum.reverse() |> Enum.join("\n") do
      "[DONE]" ->
        {:ok, :done}

      data ->
        case Jason.decode(data) do
          {:ok, event} when is_map(event) -> {:ok, event}
          _ -> :incomplete
        end
    end
  end

  defp carry(pending) do
    pending
    |> Enum.reverse()
    |> Enum.map_join(fn value -> "data: " <> value <> "\n" end)
  end
end
