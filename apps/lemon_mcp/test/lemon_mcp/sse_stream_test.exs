defmodule LemonMCP.SSEStreamTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Client.SSE.Stream

  test "parses comments, CRLF and multiline data across batches" do
    {[], event} = Stream.parse_lines([": comment", "event: custom\r", "data: first\r"], Stream.new_event())
    {events, event} = Stream.parse_lines(["data: second", "", "ignored: field"], event)

    assert events == [%{event: "custom", data: "first\nsecond"}]
    assert Stream.finalize({events, event}) == events
  end

  test "finalization flushes trailing data in wire order but not empty events" do
    parsed = Stream.parse_lines(["data: first", "", "data: last"], Stream.new_event())
    assert Stream.finalize(parsed) == [
             %{event: "message", data: "first"},
             %{event: "message", data: "last"}
           ]
    assert Stream.finalize({[], Stream.new_event()}) == []
  end
end
