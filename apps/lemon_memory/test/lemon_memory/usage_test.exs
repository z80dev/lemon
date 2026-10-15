defmodule LemonMemory.UsageTest do
  use ExUnit.Case, async: true
  alias LemonMemory.Usage

  test "character headers have deterministic grouped counts and floor percentages" do
    assert Usage.preferences("user", 860) == "USER PROFILE [62% — 860/1,375 chars]"
    assert Usage.preferences("memory", 1_474) == "MEMORY [67% — 1,474/2,200 chars]"
    assert Usage.preferences("memory", 0) == "MEMORY [0% — 0/2,200 chars]"
  end

  test "consolidation starts strictly above 80 percent, independent of rounded display" do
    refute Usage.preferences("user", 1_100) =~ "consolidate"
    assert Usage.preferences("user", 1_101) =~ "Above 80% capacity: consolidate before adding."
    refute Usage.preferences("memory", 1_760) =~ "consolidate"
    assert Usage.preferences("memory", 1_761) =~ "consolidate"
  end

  test "project headers count Unicode bytes and newline separators" do
    assert Usage.project(["é", "a"]) == "PROJECT MEMORY [2/24 facts, 4/2,000 bytes]"
    refute Usage.project(List.duplicate("a", 19)) =~ "consolidate"
    assert Usage.project(List.duplicate("a", 20)) =~ "consolidate"
    refute Usage.project([String.duplicate("a", 1_600)]) =~ "consolidate"
    assert Usage.project([String.duplicate("a", 1_601)]) =~ "consolidate"
  end
end
