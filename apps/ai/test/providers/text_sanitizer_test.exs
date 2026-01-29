defmodule Ai.Providers.TextSanitizerTest do
  use ExUnit.Case

  alias Ai.Providers.TextSanitizer

  test "sanitize returns valid utf-8 for invalid input" do
    invalid = <<0xC3, 0x28, 0xFF>>

    sanitized = TextSanitizer.sanitize(invalid)

    assert is_binary(sanitized)
    assert String.valid?(sanitized)
  end

  test "sanitize normalizes nil to empty string" do
    assert TextSanitizer.sanitize(nil) == ""
  end

  test "sanitize converts non-binary values to string" do
    assert TextSanitizer.sanitize(123) == "123"
  end
end
