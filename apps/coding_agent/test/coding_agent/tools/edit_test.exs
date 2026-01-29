defmodule CodingAgent.Tools.EditTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Edit
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Edit.tool("/tmp")

      assert tool.name == "edit"
      assert tool.label == "Edit File"
      assert tool.description =~ "Replace exact text"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["path", "old_text", "new_text"]
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/6 - basic replacement" do
    test "replaces exact text in a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello, World!")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "World",
        "new_text" => "Elixir"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Successfully replaced text"
      assert File.read!(path) == "Hello, Elixir!"
    end

    test "replaces multiline text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multi.txt")
      content = """
      line 1
      line 2
      line 3
      """
      File.write!(path, content)

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line 2",
        "new_text" => "replaced line"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) =~ "replaced line"
    end

    test "handles relative paths", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "relative.txt")
      File.write!(path, "original content")

      result = Edit.execute("call_1", %{
        "path" => "relative.txt",
        "old_text" => "original",
        "new_text" => "modified"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "modified content"
    end
  end

  describe "execute/6 - BOM handling" do
    test "preserves UTF-8 BOM", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "Hello, World!")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "World",
        "new_text" => "BOM"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert String.starts_with?(content, bom)
      assert content == bom <> "Hello, BOM!"
    end
  end

  describe "execute/6 - line endings" do
    test "preserves CRLF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "line1\r\nline2\r\nline3")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line2",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "line1\r\nreplaced\r\nline3"
    end

    test "preserves LF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lf.txt")
      File.write!(path, "line1\nline2\nline3")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line2",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "line1\nreplaced\nline3"
    end

    test "handles old_text with different line endings than file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mixed.txt")
      File.write!(path, "line1\r\nline2\r\nline3")

      # Search with LF but file has CRLF
      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line1\nline2",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "replaced"
    end
  end

  describe "execute/6 - fuzzy matching" do
    test "matches with trailing whitespace differences", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "whitespace.txt")
      File.write!(path, "hello world   \nnext line")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello world\nnext",
        "new_text" => "hello universe\nnext"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "hello universe"
    end

    test "matches smart single quotes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "quotes.txt")
      # File contains curly quote (U+2019 RIGHT SINGLE QUOTATION MARK)
      curly_quote = <<0x2019::utf8>>
      File.write!(path, "It#{curly_quote}s a test")

      result = Edit.execute("call_1", %{
        "path" => path,
        # Search with ASCII quote
        "old_text" => "It's a test",
        "new_text" => "It was a test"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "It was a test"
    end

    test "matches smart double quotes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dquotes.txt")
      # File contains curly quotes (U+201C LEFT, U+201D RIGHT)
      left_quote = <<0x201C::utf8>>
      right_quote = <<0x201D::utf8>>
      File.write!(path, "She said #{left_quote}hello#{right_quote}")

      result = Edit.execute("call_1", %{
        "path" => path,
        # Search with ASCII quotes
        "old_text" => "She said \"hello\"",
        "new_text" => "She said \"hi\""
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "hi"
    end

    test "matches unicode dashes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dashes.txt")
      # File contains em-dash (U+2014)
      em_dash = <<0x2014::utf8>>
      File.write!(path, "hello#{em_dash}world")

      result = Edit.execute("call_1", %{
        "path" => path,
        # Search with ASCII hyphen
        "old_text" => "hello-world",
        "new_text" => "hello_world"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "hello_world"
    end

    test "matches with multiple space normalization", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "spaces.txt")
      File.write!(path, "hello    world")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello world",
        "new_text" => "hello_world"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "hello_world"
    end
  end

  describe "execute/6 - uniqueness check" do
    test "returns error for multiple occurrences", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dup.txt")
      File.write!(path, "hello world hello universe")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello",
        "new_text" => "hi"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "2 occurrences"
      assert msg =~ "must be unique"
    end

    test "succeeds when text appears exactly once", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unique.txt")
      File.write!(path, "hello world")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello",
        "new_text" => "hi"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "hi world"
    end
  end

  describe "execute/6 - error handling" do
    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      result = Edit.execute("call_1", %{
        "path" => Path.join(tmp_dir, "nonexistent.txt"),
        "old_text" => "hello",
        "new_text" => "hi"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "File not found"
    end

    test "returns error when text not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "notfound.txt")
      File.write!(path, "hello world")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "xyz",
        "new_text" => "abc"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Could not find the exact text"
    end

    test "returns error when replacement produces no change", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nochange.txt")
      File.write!(path, "hello world")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "hello",
        "new_text" => "hello"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "No changes made"
    end
  end

  describe "execute/6 - diff generation" do
    test "includes diff in result", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diff.txt")
      File.write!(path, "line1\nline2\nline3\nline4\nline5")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line3",
        "new_text" => "replaced"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Successfully replaced"
      assert details.diff =~ "replaced"
      assert is_integer(details.first_changed_line)
    end

    test "first_changed_line is correct", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "line.txt")
      File.write!(path, "line1\nline2\nline3")

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "line2",
        "new_text" => "changed"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{first_changed_line: line}} = result
      assert line == 2
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration.txt")
      File.write!(path, "test content")

      tool = Edit.tool(tmp_dir)

      result = tool.execute.("call_1", %{
        "path" => path,
        "old_text" => "test",
        "new_text" => "new"
      }, nil, nil)

      assert %AgentToolResult{} = result
      assert File.read!(path) == "new content"
    end
  end

  describe "execute/6 - abort signal handling" do
    test "returns error when signal is aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort_test.txt")
      File.write!(path, "original content")

      # Create and abort the signal
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "original",
        "new_text" => "modified"
      }, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
      # File should not be modified
      assert File.read!(path) == "original content"
    end

    test "proceeds when signal is not aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_abort_test.txt")
      File.write!(path, "original content")

      # Create signal but don't abort it
      signal = AbortSignal.new()

      result = Edit.execute("call_1", %{
        "path" => path,
        "old_text" => "original",
        "new_text" => "modified"
      }, signal, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "modified content"
    end
  end
end
