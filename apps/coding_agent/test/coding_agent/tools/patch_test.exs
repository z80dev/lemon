defmodule CodingAgent.Tools.PatchTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Patch
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Patch.tool("/tmp")

      assert tool.name == "patch"
      assert tool.label == "Apply Patch"
      assert tool.description =~ "patch"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["patch_text"]
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/6 - file addition" do
    test "adds a new file", %{tmp_dir: tmp_dir} do
      new_file = Path.join(tmp_dir, "newfile.txt")

      patch_text = """
      *** Add File: newfile.txt
      +line 1
      +line 2
      +line 3
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Patch applied successfully"
      assert File.exists?(new_file)
      assert File.read!(new_file) == "line 1\nline 2\nline 3"
      assert details.additions > 0
    end

    test "returns error when adding existing file", %{tmp_dir: tmp_dir} do
      existing = Path.join(tmp_dir, "existing.txt")
      File.write!(existing, "already here")

      patch_text = """
      *** Add File: existing.txt
      +new content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "already exists"
    end
  end

  describe "execute/6 - file deletion" do
    test "deletes an existing file", %{tmp_dir: tmp_dir} do
      file_to_delete = Path.join(tmp_dir, "delete_me.txt")
      File.write!(file_to_delete, "goodbye\nworld")

      patch_text = """
      *** Delete File: delete_me.txt
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Patch applied successfully"
      refute File.exists?(file_to_delete)
      assert details.removals > 0
    end

    test "returns error when deleting non-existent file", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Delete File: nonexistent.txt
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found"
    end
  end

  describe "execute/6 - file update" do
    test "updates existing file with hunks", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "update.txt")
      File.write!(file, "line 1\nline 2\nline 3\nline 4")

      patch_text = """
      *** Update File: update.txt
      @@ context
       line 2
      -line 3
      +replaced line 3
       line 4
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Patch applied successfully"
      assert File.read!(file) == "line 1\nline 2\nreplaced line 3\nline 4"
    end

    test "handles multiple hunks in same file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "multi_hunk.txt")
      File.write!(file, "aaa\nbbb\nccc\nddd\neee")

      patch_text = """
      *** Update File: multi_hunk.txt
      @@ first hunk
       aaa
      -bbb
      +BBB
       ccc
      @@ second hunk
       ccc
      -ddd
      +DDD
       eee
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "aaa\nBBB\nccc\nDDD\neee"
    end

    test "adds lines without removing", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "add_only.txt")
      File.write!(file, "before\nafter")

      patch_text = """
      *** Update File: add_only.txt
      @@ add lines
       before
      +inserted line
       after
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "before\ninserted line\nafter"
    end

    test "removes lines without adding", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "remove_only.txt")
      File.write!(file, "keep\nremove\nkeep")

      patch_text = """
      *** Update File: remove_only.txt
      @@ remove
       keep
      -remove
       keep
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "keep\nkeep"
    end

    test "returns error when context not found", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "nocontext.txt")
      File.write!(file, "actual content")

      patch_text = """
      *** Update File: nocontext.txt
      @@ hunk
       wrong context
      -something
      +replacement
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Context not found"
    end
  end

  describe "execute/6 - file move (rename)" do
    test "moves file to new location", %{tmp_dir: tmp_dir} do
      old_path = Path.join(tmp_dir, "old_name.txt")
      new_path = Path.join(tmp_dir, "new_name.txt")
      File.write!(old_path, "content\nhere")

      patch_text = """
      *** Update File: old_name.txt
      *** Move to: new_name.txt
      @@ update
       content
      -here
      +there
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      refute File.exists?(old_path)
      assert File.exists?(new_path)
      assert File.read!(new_path) == "content\nthere"
    end
  end

  describe "execute/6 - error handling" do
    test "returns error when patch_text is missing", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text is required"} = result
    end

    test "returns error when patch_text is empty", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{"patch_text" => ""}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text is required"} = result
    end

    test "returns error when no operations found", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{"patch_text" => "just some text"}, nil, nil, tmp_dir, [])
      assert {:error, "No patch operations found"} = result
    end

    test "returns error when updating non-existent file", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Update File: nonexistent.txt
      @@ hunk
       context
      -old
      +new
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found"
    end
  end

  describe "execute/6 - abort signal handling" do
    test "returns error when signal is aborted", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      patch_text = """
      *** Add File: test.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds when signal is not aborted", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      new_file = Path.join(tmp_dir, "ok.txt")

      patch_text = """
      *** Add File: ok.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, signal, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(new_file)
    end
  end

  describe "execute/6 - Begin/End Patch markers" do
    test "handles Begin Patch and End Patch markers", %{tmp_dir: tmp_dir} do
      new_file = Path.join(tmp_dir, "markers.txt")

      patch_text = """
      *** Begin Patch
      *** Add File: markers.txt
      +content with markers
      *** End Patch
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(new_file)
    end
  end

  describe "execute/6 - line ending preservation" do
    test "preserves CRLF line endings", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "crlf.txt")
      File.write!(file, "line1\r\nline2\r\nline3")

      patch_text = """
      *** Update File: crlf.txt
      @@ hunk
       line1
      -line2
      +replaced
       line3
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(file)
      assert content == "line1\r\nreplaced\r\nline3"
    end
  end

  describe "execute/6 - nested directory creation" do
    test "creates parent directories for new files", %{tmp_dir: tmp_dir} do
      new_file = Path.join([tmp_dir, "nested", "dir", "file.txt"])

      patch_text = """
      *** Add File: nested/dir/file.txt
      +nested content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(new_file)
      assert File.read!(new_file) == "nested content"
    end
  end

  describe "execute/6 - multiple operations" do
    test "applies multiple operations in sequence", %{tmp_dir: tmp_dir} do
      existing = Path.join(tmp_dir, "existing.txt")
      File.write!(existing, "original")

      patch_text = """
      *** Add File: new1.txt
      +new file 1
      *** Add File: new2.txt
      +new file 2
      *** Update File: existing.txt
      @@ update
      -original
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "3 files changed"
      assert File.exists?(Path.join(tmp_dir, "new1.txt"))
      assert File.exists?(Path.join(tmp_dir, "new2.txt"))
      assert File.read!(existing) == "modified"
      assert details.additions > 0
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      tool = Patch.tool(tmp_dir)

      patch_text = """
      *** Add File: integration.txt
      +test
      """

      result = tool.execute.("call_1", %{"patch_text" => patch_text}, nil, nil)

      assert %AgentToolResult{} = result
      assert File.exists?(Path.join(tmp_dir, "integration.txt"))
    end
  end
end
