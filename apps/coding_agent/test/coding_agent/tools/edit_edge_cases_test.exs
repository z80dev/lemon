defmodule CodingAgent.Tools.EditEdgeCasesTest do
  @moduledoc """
  Edge case tests for the Edit tool.

  Tests unicode handling, BOM preservation, line endings, large files,
  concurrent access, and special characters.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Edit
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal

  @moduletag :tmp_dir

  describe "execute/6 - unicode character handling" do
    test "handles emoji in text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "emoji.txt")
      File.write!(path, "Hello 👋 World")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "👋",
        "new_text" => "🌍"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "🌍"
    end

    test "handles right-to-left text (Arabic)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rtl.txt")
      arabic_text = "مرحبا"
      File.write!(path, "Start #{arabic_text} End")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => arabic_text,
        "new_text" => "السلام"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) =~ "السلام"
    end

    test "handles surrogate pairs in replacement text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "surrogate.txt")
      File.write!(path, "hello world")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello",
        "new_text" => "𝕳𝖎"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) =~ "𝕳"
    end

    test "handles CJK characters", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "cjk.txt")
      File.write!(path, "Hello 世界")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "世界",
        "new_text" => "世界你好"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) =~ "世界你好"
    end
  end

  describe "execute/6 - BOM edge cases" do
    test "preserves BOM with unicode content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom_unicode.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "café 🌍")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "café",
        "new_text" => "coffee"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert String.starts_with?(content, bom)
      assert content =~ "coffee"
    end

    test "handles BOM with CRLF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom_crlf.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "line1\r\nline2\r\nline3")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line2",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert String.starts_with?(content, bom)
      assert content =~ "replaced"
    end
  end

  describe "execute/6 - line ending edge cases" do
    test "handles CRLF file and preserves line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "line1\r\nline2\r\nline3")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line2",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "line1\r\nreplaced\r\nline3"
    end

    test "replaces multiline text with LF in CRLF file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multiline_crlf.txt")
      File.write!(path, "start\r\nmiddle\r\nend")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "start\nmiddle",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "replaced"
    end

    test "insertion that creates new lines preserves file line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "insert_lines.txt")
      File.write!(path, "line1\r\nline2\r\nline3")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line2",
        "new_text" => "line2a\nline2b"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "line2a\r\nline2b"
    end
  end

  describe "execute/6 - large file handling" do
    test "handles file with many lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "many_lines.txt")
      lines = Enum.map_join(1..1000, "\n", fn n -> "line#{n}" end)
      File.write!(path, lines)

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line500",
        "new_text" => "changed"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "changed"
      refute content =~ "line500"
    end

    test "large replacement text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large_replace.txt")
      File.write!(path, "needle in haystack")

      large_replacement = String.duplicate("x", 10_000)
      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "needle",
        "new_text" => large_replacement
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert byte_size(content) > 10_000
    end
  end

  describe "execute/6 - abort signal handling" do
    test "respects abort signal before execution", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort.txt")
      File.write!(path, "original")

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "original",
        "new_text" => "should abort"
      }, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
      assert File.read!(path) == "original"
    end

    test "non-aborted signal allows execution", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_abort.txt")
      File.write!(path, "original")

      signal = AbortSignal.new()

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "original",
        "new_text" => "modified"
      }, signal, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "modified"
    end
  end

  describe "execute/6 - special characters in replacements" do
    test "handles backslash in replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "backslash.txt")
      File.write!(path, "normal path/file")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "path/file",
        "new_text" => "path\\file"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) =~ "path\\file"
    end

    test "handles special regex characters in replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "regex_special.txt")
      File.write!(path, "match this")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "match",
        "new_text" => "$1.*+?{}[]()"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) =~ "$1.*+?"
    end

    test "handles control characters in replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "control_chars.txt")
      File.write!(path, "line1_X_line2")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "_X_",
        "new_text" => "\t"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "line1\tline2"
    end

    test "handles replacement with newlines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "newlines.txt")
      File.write!(path, "start middle end")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "start middle end",
        "new_text" => "line1\nline2\nline3"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "line1\nline2\nline3"
    end
  end

  describe "execute/6 - boundary conditions" do
    test "edit at very beginning of file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "boundary_start.txt")
      File.write!(path, "needle rest of file")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "needle",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "replaced rest of file"
    end

    test "edit at very end of file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "boundary_end.txt")
      File.write!(path, "rest of file needle")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "needle",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "rest of file replaced"
    end

    test "single character file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "single_char.txt")
      File.write!(path, "x")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "x",
        "new_text" => "y"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "y"
    end

    test "entire file is the search text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "entire_file.txt")
      File.write!(path, "entire content")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "entire content",
        "new_text" => "new entire content"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "new entire content"
    end

    test "replacing with empty string at file boundary", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_boundary.txt")
      File.write!(path, "prefix_content_suffix")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "prefix_",
        "new_text" => ""
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content_suffix"
    end
  end

  describe "execute/6 - error conditions" do
    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      result = Edit.execute("call_1", %{
        "path" => "nonexistent.txt",
        "old_text" => "something",
        "new_text" => "else"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "No such file"
    end

    test "returns error when text not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "not_found.txt")
      File.write!(path, "hello world")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "nonexistent",
        "new_text" => "replacement"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not find" or msg =~ "not found"
    end

    test "returns error when text occurs multiple times", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multiple.txt")
      File.write!(path, "hello hello hello")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello",
        "new_text" => "hi"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "occurrence" or msg =~ "unique"
    end

    test "returns error when replacement produces no change", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_change.txt")
      File.write!(path, "same content")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "same",
        "new_text" => "same"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "no change" or msg =~ "identical"
    end
  end

  describe "execute/6 - grapheme handling" do
    test "handles multi-codepoint emoji", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multi_emoji.txt")
      # Family emoji (multi-codepoint)
      family = "👨‍👩‍👧‍👦"
      File.write!(path, "Start #{family} End")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => family,
        "new_text" => "family"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "Start family End"
    end
  end
end
