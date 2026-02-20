defmodule LemonGateway.Discord.FormatterTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Discord.Formatter

  test "chunks text at discord limit" do
    text = String.duplicate("a", 4_200)

    chunks = Formatter.chunk_text(text)

    assert length(chunks) == 3
    assert Enum.all?(chunks, fn chunk -> byte_size(chunk) <= 2_000 end)
    assert Enum.join(chunks, "") == text
  end

  test "formats errors with marker" do
    assert Formatter.format_error(:boom) == "❌ boom"
  end

  test "builds tool call embed" do
    embed = Formatter.tool_call_embed(%{name: "search", status: "ok", detail: "done"})

    assert embed.title == "Tool Call: search"
    assert embed.color == 0x57F287
  end
end
