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

  # ------- chunk_text additional tests -------

  test "chunk_text with nil returns empty list" do
    assert Formatter.chunk_text(nil) == []
  end

  test "chunk_text with empty string returns empty list" do
    assert Formatter.chunk_text("") == []
  end

  test "chunk_text with short text returns single chunk" do
    text = "hello world"
    chunks = Formatter.chunk_text(text)

    assert length(chunks) == 1
    assert hd(chunks) == "hello world"
  end

  test "chunk_text splits at newlines" do
    line = String.duplicate("x", 1_500)
    text = line <> "\n" <> line

    chunks = Formatter.chunk_text(text)

    assert length(chunks) == 2
    assert Enum.all?(chunks, fn chunk -> byte_size(chunk) <= 2_000 end)
  end

  test "chunk_text splits at spaces" do
    word = String.duplicate("y", 500)
    # 4 words of 500 chars each joined by spaces = 2003 chars total, exceeds 2000
    text = Enum.join([word, word, word, word], " ")

    chunks = Formatter.chunk_text(text)

    assert length(chunks) >= 2
    assert Enum.all?(chunks, fn chunk -> byte_size(chunk) <= 2_000 end)
  end

  test "chunk_text with custom limit parameter" do
    text = String.duplicate("z", 100)
    chunks = Formatter.chunk_text(text, 30)

    assert length(chunks) >= 4
    assert Enum.all?(chunks, fn chunk -> byte_size(chunk) <= 30 end)
    assert Enum.join(chunks, "") == text
  end

  test "chunk_text with text exactly at limit boundary" do
    text = String.duplicate("b", 2_000)
    chunks = Formatter.chunk_text(text)

    assert length(chunks) == 1
    assert hd(chunks) == text
  end

  # ------- format_error additional tests -------

  test "format_error with string error" do
    assert Formatter.format_error("something went wrong") == "❌ something went wrong"
  end

  test "format_error with integer error code" do
    assert Formatter.format_error(500) == "❌ 500"
  end

  # ------- tool_call_embed additional tests -------

  test "tool_call_embed with string keys" do
    embed = Formatter.tool_call_embed(%{"name" => "deploy", "status" => "ok", "detail" => "success"})

    assert embed.title == "Tool Call: deploy"
    assert embed.color == 0x57F287
    assert embed.description == "success"
  end

  test "tool_call_embed missing name defaults to tool" do
    embed = Formatter.tool_call_embed(%{status: "ok", detail: "done"})

    assert embed.title == "Tool Call: tool"
  end

  test "tool_call_embed missing status defaults to running with default color" do
    embed = Formatter.tool_call_embed(%{name: "search"})

    assert embed.footer.text == "status: running"
    assert embed.color == 0x5865F2
  end

  test "tool_call_embed error status gets red color" do
    embed = Formatter.tool_call_embed(%{name: "search", status: "error", detail: "failed"})

    assert embed.color == 0xED4245
  end

  test "tool_call_embed unknown status gets default blurple color" do
    embed = Formatter.tool_call_embed(%{name: "search", status: "pending", detail: ""})

    assert embed.color == 0x5865F2
  end

  test "tool_call_embed detail is included in description" do
    embed = Formatter.tool_call_embed(%{name: "fetch", status: "ok", detail: "fetched 42 records"})

    assert embed.description == "fetched 42 records"
  end

  test "tool_call_embed footer shows status" do
    embed = Formatter.tool_call_embed(%{name: "compile", status: "done", detail: ""})

    assert embed.footer == %{text: "status: done"}
  end
end
