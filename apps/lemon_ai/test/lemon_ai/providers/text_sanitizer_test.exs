defmodule LemonAi.Providers.TextSanitizerTest do
  use ExUnit.Case, async: true

  alias LemonAi.Providers.TextSanitizer

  test "passes valid UTF-8 through without normalizing or truncating it" do
    for text <- [
          "",
          "plain ASCII",
          "Hello 你好 مرحبا שלום 🌟",
          "   \t\n\r  ",
          "line1\nline2\tline3\r\n",
          "before\uFFFDafter",
          "\uFEFFbefore\0after",
          "\uE000\u200B\u200C\u200D",
          "cafe\u0301",
          String.duplicate("Hello 🌟 ", 10_000)
        ] do
      assert TextSanitizer.sanitize(text) == text
    end
  end

  test "replaces invalid UTF-8 after keeping the valid prefix" do
    for {input, expected} <- [
          {"hello" <> <<0xFF>>, "hello\uFFFD"},
          {"ab" <> <<0xFF>> <> "cd", "ab\uFFFD"},
          {"abc" <> <<0xC3, 0x28>> <> "def", "abc\uFFFD"},
          {<<0x80, 0x80>>, "\uFFFD"},
          {<<0xC0, 0xAF>>, "\uFFFD"},
          {String.duplicate(<<0xFF, 0xFE>>, 1000), "\uFFFD"}
        ] do
      assert TextSanitizer.sanitize(input) == expected
    end
  end

  test "replaces incomplete multibyte sequences at the end of the input" do
    for {prefix, incomplete} <- [
          {"hello", <<0xC2>>},
          {"test", <<0xE2, 0x82>>},
          {"data", <<0xF0, 0x9F, 0x98>>},
          {"", <<0xE0>>}
        ] do
      assert TextSanitizer.sanitize(prefix <> incomplete) == prefix <> "\uFFFD"
    end
  end

  test "normalizes nil to empty text and stringifies non-binary input" do
    for {input, expected} <- [
          {nil, ""},
          {:hello, "hello"},
          {42, "42"},
          {-123, "-123"},
          {0, "0"},
          {3.14, "3.14"},
          {true, "true"},
          {false, "false"},
          {~c"hello", "hello"}
        ] do
      assert TextSanitizer.sanitize(input) == expected
    end
  end
end
