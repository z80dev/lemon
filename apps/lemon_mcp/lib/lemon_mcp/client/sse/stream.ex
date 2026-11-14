defmodule LemonMCP.Client.SSE.Stream do
  @moduledoc false

  # Events accumulate in reverse order to support incremental consumers.
  def parse_lines(lines, event) do
    Enum.reduce(lines, {[], event}, fn line, {events, event} ->
      parse_line(String.trim_trailing(line, "\r"), events, event)
    end)
  end

  def finalize({events, event}) do
    {events, _event} = parse_line("", events, event)
    Enum.reverse(events)
  end

  defp parse_line("", events, %{data: data} = event) when data != [] do
    {[%{event: event.event || "message", data: Enum.reverse(data) |> Enum.join("\n")} | events],
     new_event()}
  end

  defp parse_line("", events, _event), do: {events, new_event()}
  defp parse_line(":" <> _comment, events, event), do: {events, event}

  defp parse_line("event:" <> value, events, event) do
    {events, %{event | event: trim_sse_value(value)}}
  end

  defp parse_line("data:" <> value, events, event) do
    {events, %{event | data: [trim_sse_value(value) | event.data]}}
  end

  defp parse_line(_line, events, event), do: {events, event}

  def new_event, do: %{event: "message", data: []}
  defp trim_sse_value(" " <> value), do: value
  defp trim_sse_value(value), do: value


end
