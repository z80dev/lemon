defmodule LemonMemory.TextTest do
  use ExUnit.Case, async: true

  alias LemonMemory.Text

  test "byte clipping keeps complete UTF-8 codepoints" do
    assert Text.clip_bytes(nil, 4) == ""
    assert Text.clip_bytes("hello", 8) == "hello"
    assert Text.clip_bytes("a😀b", 4) == "a"
    assert Text.clip_bytes("a😀b", 5) == "a😀"
    assert Text.clip_bytes("😀", 0) == ""
    assert Text.boundary("a😀b", 4) == 1
    assert Text.boundary("a😀b", 5) == 5
    assert Text.boundary(<<97, 255>>, 2) == 1
  end

  test "session previews retain whole combining and emoji graphemes" do
    assert Text.clip_bytes(nil, 4, :grapheme) == ""
    assert Text.clip_bytes("éx", 1) == "e"
    assert Text.clip_bytes("éx", 1, :grapheme) == ""
    assert Text.clip_bytes("éx", 3, :grapheme) == "é"
    assert Text.clip_bytes("👍🏽!", 4, :grapheme) == ""
    assert Text.clip_bytes("👍🏽!", 8, :grapheme) == "👍🏽"
    assert Text.clip_bytes("short", 100, :grapheme) == "short"
  end
end
