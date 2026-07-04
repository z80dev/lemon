defmodule Ai.TokensTest do
  use ExUnit.Case, async: true

  alias Ai.Tokens

  describe "estimate_chars/1" do
    test "uses character count divided by four" do
      assert Tokens.estimate_chars("abcd") == 1
      assert Tokens.estimate_chars("abcdefg") == 1
      assert Tokens.estimate_chars("abcdefgh") == 2
    end

    test "counts UTF-8 text by characters, not bytes" do
      assert String.length("éééé") == 4
      assert byte_size("éééé") == 8
      assert Tokens.estimate_chars("éééé") == 1
    end
  end

  describe "estimate_char_count/1" do
    test "uses a precomputed character count" do
      assert Tokens.estimate_char_count(7) == 1
      assert Tokens.estimate_char_count(8) == 2
    end
  end

  describe "estimate_bytes/1" do
    test "uses byte size divided by four" do
      assert Tokens.estimate_bytes("abcd") == 1
      assert Tokens.estimate_bytes("abcdefg") == 1
      assert Tokens.estimate_bytes("abcdefgh") == 2
    end

    test "counts UTF-8 text by bytes" do
      assert Tokens.estimate_bytes("éééé") == 2
    end
  end

  describe "estimate_byte_count/1" do
    test "uses a precomputed byte count" do
      assert Tokens.estimate_byte_count(7) == 1
      assert Tokens.estimate_byte_count(8) == 2
    end
  end

  describe "boundary cases" do
    test "empty input estimates zero tokens" do
      assert Tokens.estimate_chars("") == 0
      assert Tokens.estimate_bytes("") == 0
      assert Tokens.estimate_char_count(0) == 0
      assert Tokens.estimate_byte_count(0) == 0
    end
  end
end
