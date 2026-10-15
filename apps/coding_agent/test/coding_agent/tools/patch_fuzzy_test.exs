defmodule CodingAgent.Tools.PatchFuzzyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Patch
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  test "normalizes whitespace and punctuation without rewriting context", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "untouched  \n\tlabel = “hello”—world  \n\told   value\n  after\t\n")

    assert %AgentToolResult{} =
             patch(cwd, " label = \"hello\"-world\n-old value\n+new value\n after")

    assert File.read!(path) ==
             "untouched  \n\tlabel = “hello”—world  \nnew value\n  after\t\n"
  end

  test "rejects multiple normalized matches without writing", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    original = "\told value\n  old   value  \n"
    File.write!(path, original)

    assert {:error, message} = patch(cwd, "-old value\n+new value")
    assert message =~ "Ambiguous patch hunk"
    assert message =~ "2 locations"
    assert File.read!(path) == original
  end

  test "exact match wins over other normalized matches", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "old value\n\told value\n")

    assert %AgentToolResult{} = patch(cwd, "-old value\n+new value")
    assert File.read!(path) == "new value\n\told value\n"
  end

  test "a normalized miss retains the context-not-found error", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "different\n")

    assert {:error, message} = patch(cwd, "-old value\n+new value")
    assert message =~ "Context not found"
    assert File.read!(path) == "different\n"
  end

  test "fuzzy matching retains CRLF outside the replaced lines", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "before\r\n\told value\r\nafter\r\n")

    assert %AgentToolResult{} = patch(cwd, "-old value\n+new value")
    assert File.read!(path) == "before\r\nnew value\r\nafter\r\n"
  end

  defp patch(cwd, hunk) do
    Patch.execute(
      "patch",
      %{"patch_text" => "*** Begin Patch\n*** Update File: file.txt\n@@\n#{hunk}\n*** End Patch"},
      nil,
      nil,
      cwd,
      []
    )
  end
end
