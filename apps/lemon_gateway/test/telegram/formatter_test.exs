defmodule LemonGateway.Telegram.FormatterTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Telegram.Formatter

  defp utf16_len(text) when is_binary(text) do
    bin = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    div(byte_size(bin), 2)
  end

  test "prepare_for_telegram/1 returns empty output for nil" do
    assert {"", nil} == Formatter.prepare_for_telegram(nil)
  end

  test "prepare_for_telegram/1 returns plain text with no opts when no formatting is present" do
    assert {"hello world", nil} == Formatter.prepare_for_telegram("hello world")
  end

  test "renders bold + inline code into Telegram entities (no parse_mode)" do
    md = "Hi **bold** and `code`."

    {text, opts} = Formatter.prepare_for_telegram(md)
    assert text == "Hi bold and code."
    assert %{entities: entities} = opts

    bold =
      Enum.find(entities, fn e ->
        e["type"] == "bold" and e["offset"] == utf16_len("Hi ") and e["length"] == utf16_len("bold")
      end)

    assert is_map(bold), "expected a bold entity, got: #{inspect(entities)}"

    code =
      Enum.find(entities, fn e ->
        e["type"] == "code" and e["offset"] == utf16_len("Hi bold and ") and
          e["length"] == utf16_len("code")
      end)

    assert is_map(code), "expected a code entity, got: #{inspect(entities)}"
  end

  test "renders links as text_link entities" do
    md = "[example](http://example.com)"
    {text, opts} = Formatter.prepare_for_telegram(md)

    assert text == "example"
    assert %{entities: [ent]} = opts
    assert ent["type"] == "text_link"
    assert ent["offset"] == 0
    assert ent["length"] == utf16_len("example")
    assert ent["url"] == "http://example.com"
  end

  test "renders fenced code blocks as pre entities (with language when present)" do
    md = "```elixir\nIO.puts(\"hi\")\n```"
    {text, opts} = Formatter.prepare_for_telegram(md)

    refute String.contains?(text, "```")
    assert String.contains?(text, "IO.puts(\"hi\")")

    assert %{entities: [ent]} = opts
    assert ent["type"] == "pre"
    assert ent["offset"] == 0
    assert ent["length"] == utf16_len(text)
    assert ent["language"] == "elixir"
  end

  test "uses UTF-16 offsets for entities (emoji is 2 code units)" do
    md = "**😀** ok"
    {text, opts} = Formatter.prepare_for_telegram(md)
    assert text == "😀 ok"

    assert %{entities: [ent]} = opts
    assert ent["type"] == "bold"
    assert ent["offset"] == 0
    assert ent["length"] == 2
  end
end

