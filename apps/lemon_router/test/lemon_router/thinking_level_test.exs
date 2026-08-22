defmodule LemonRouter.ThinkingLevelTest do
  use ExUnit.Case, async: true

  alias LemonRouter.ThinkingLevel

  test "allowed_strings/0 lists router-supported values" do
    assert ThinkingLevel.allowed_strings() == ~w(high low medium minimal off xhigh)
  end

  test "normalize/1 maps known strings to atoms" do
    assert ThinkingLevel.normalize("high") == :high
    assert ThinkingLevel.normalize("extended") == nil
  end
end
