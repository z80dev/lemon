defmodule LemonRouter.ThinkingLevelTest do
  use ExUnit.Case, async: true

  alias LemonRouter.ThinkingLevel

  test "allowed_strings/0 lists router-supported values" do
    assert ThinkingLevel.allowed_strings() == ~w(auto high low medium minimal off xhigh)
  end

  test "normalize/1 maps known strings to atoms" do
    assert ThinkingLevel.normalize("high") == :high
    assert ThinkingLevel.normalize("auto") == :auto
    assert ThinkingLevel.valid_string?("auto")
    assert ThinkingLevel.normalize("extended") == nil
  end
end
