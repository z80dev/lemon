defmodule CodingAgent.Tools.HashlineEditTest do
  @moduledoc """
  Tests for the HashlineEdit tool (line-addressable editing with hash validation).
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.HashlineEdit
  alias CodingAgent.Tools.Hashline

  @test_dir System.tmp_dir!() |> Path.join("hashline_edit_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    %{cwd: @test_dir}
  end

  defp write_test_file(cwd, name, content) do
    path = Path.join(cwd, name)
    File.write!(path, content)
    path
  end

  defp make_tag(line, content) do
    hash = Hashline.compute_line_hash(content)
    "#{line}##{hash}"
  end

  # ============================================================================
  # Tool Definition
  # ============================================================================

  describe "tool/2" do
    test "returns AgentTool struct", %{cwd: cwd} do
      tool = HashlineEdit.tool(cwd)
      assert tool.name == "hashline_edit"
      assert is_binary(tool.description)
      assert tool.label == "Hashline Edit"
      assert is_map(tool.parameters)
      assert is_function(tool.execute, 4)
    end

    test "requires path and edits parameters", %{cwd: cwd} do
      tool = HashlineEdit.tool(cwd)
      required = tool.parameters["required"]
      assert "path" in required
      assert "edits" in required
    end
  end

  # ============================================================================
  # Parameter Validation
  # ============================================================================

  describe "parameter validation" do
    test "rejects missing path", %{cwd: cwd} do
      result = HashlineEdit.execute("call-1", %{"edits" => [%{"op" => "set"}]}, nil, nil, cwd, [])
      assert {:error, "Missing required parameter: path"} = result
    end

    test "rejects missing edits", %{cwd: cwd} do
      result = HashlineEdit.execute("call-1", %{"path" => "test.txt"}, nil, nil, cwd, [])
      assert {:error, "Missing required parameter: edits"} = result
    end

    test "rejects empty edits array", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "hello")
      result = HashlineEdit.execute("call-1", %{"path" => "test.txt", "edits" => []}, nil, nil, cwd, [])
      assert {:error, "Edits array cannot be empty"} = result
    end
  end

  # ============================================================================
  # Set Operation
  # ============================================================================

  describe "set operation" do
    test "replaces a single line", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      tag = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "set", "tag" => tag, "content" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nBBB\nccc"
    end

    test "reports noop when content unchanged", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      tag = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "set", "tag" => tag, "content" => ["bbb"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.noop_edits != nil
    end

    test "fails on stale hash", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "set", "tag" => "2#ZZ", "content" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, msg} = result
      assert msg =~ "changed since last read"
    end
  end

  # ============================================================================
  # Replace Operation
  # ============================================================================

  describe "replace operation" do
    test "replaces a range of lines", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc\nddd")
      first = make_tag(2, "bbb")
      last = make_tag(3, "ccc")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "first" => first, "last" => last, "content" => ["XXX"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nXXX\nddd"
    end

    test "expands a single line to multiple", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      first = make_tag(2, "bbb")
      last = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "first" => first, "last" => last, "content" => ["x", "y", "z"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nx\ny\nz\nccc"
    end
  end

  # ============================================================================
  # Append Operation
  # ============================================================================

  describe "append operation" do
    test "inserts after a line", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      after_tag = make_tag(1, "aaa")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "append", "after" => after_tag, "content" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nNEW\nbbb\nccc"
    end

    test "appends at EOF without anchor", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "append", "content" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nbbb\nNEW"
    end
  end

  # ============================================================================
  # Prepend Operation
  # ============================================================================

  describe "prepend operation" do
    test "inserts before a line", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      before_tag = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "prepend", "before" => before_tag, "content" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nNEW\nbbb\nccc"
    end

    test "prepends at BOF without anchor", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "prepend", "content" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "NEW\naaa\nbbb"
    end
  end

  # ============================================================================
  # Insert Operation
  # ============================================================================

  describe "insert operation" do
    test "inserts between two lines", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      after_tag = make_tag(1, "aaa")
      before_tag = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "insert", "after" => after_tag, "before" => before_tag, "content" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nNEW\nbbb\nccc"
    end
  end

  # ============================================================================
  # Multiple Edits
  # ============================================================================

  describe "multiple edits" do
    test "applies multiple non-overlapping edits", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc\nddd\neee")
      tag2 = make_tag(2, "bbb")
      tag4 = make_tag(4, "ddd")

      params = %{
        "path" => "test.txt",
        "edits" => [
          %{"op" => "set", "tag" => tag2, "content" => ["BBB"]},
          %{"op" => "set", "tag" => tag4, "content" => ["DDD"]}
        ]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nBBB\nccc\nDDD\neee"
    end
  end

  # ============================================================================
  # Error Cases
  # ============================================================================

  describe "error handling" do
    test "returns error for non-existent file", %{cwd: cwd} do
      params = %{
        "path" => "nonexistent.txt",
        "edits" => [%{"op" => "set", "tag" => "1#ZZ", "content" => ["x"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, "File not found: nonexistent.txt"} = result
    end

    test "returns error for invalid op", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "hello")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "delete_all", "content" => []}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, "Unknown edit operation: delete_all"} = result
    end

    test "returns error for missing tag in set op", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "hello")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "set", "content" => ["x"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, msg} = result
      assert msg =~ "Missing required field 'tag'"
    end
  end

  # ============================================================================
  # parse_edits/1
  # ============================================================================

  describe "parse_edits/1" do
    test "parses set edit" do
      tag = make_tag(1, "hello")
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "set", "tag" => tag, "content" => ["world"]}])
      assert edit.op == :set
      assert edit.tag.line == 1
      assert edit.content == ["world"]
    end

    test "parses replace edit" do
      first = make_tag(1, "a")
      last = make_tag(3, "c")
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "replace", "first" => first, "last" => last, "content" => ["x"]}])
      assert edit.op == :replace
      assert edit.first.line == 1
      assert edit.last.line == 3
    end

    test "parses append without anchor" do
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "append", "content" => ["new"]}])
      assert edit.op == :append
      assert edit.after == nil
    end

    test "parses prepend without anchor" do
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "prepend", "content" => ["new"]}])
      assert edit.op == :prepend
      assert edit.before == nil
    end

    test "parses replaceText edit" do
      {:ok, [edit]} =
        HashlineEdit.parse_edits([
          %{"op" => "replaceText", "old_text" => "hello", "new_text" => "world", "all" => true}
        ])

      assert edit == %{op: :replace_text, old_text: "hello", new_text: "world", all: true}
    end

    test "returns error for replaceText with empty old_text" do
      assert {:error, msg} =
               HashlineEdit.parse_edits([
                 %{"op" => "replaceText", "old_text" => "", "new_text" => "world"}
               ])

      assert msg =~ "replaceText requires non-empty 'old_text'"
    end

    test "returns error for unknown op" do
      assert {:error, _} = HashlineEdit.parse_edits([%{"op" => "unknown", "content" => []}])
    end
  end

  # ============================================================================
  # BOM & Line Ending Preservation
  # ============================================================================

  describe "file format preservation" do
    test "preserves CRLF line endings", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\r\nbbb\r\nccc")
      # Hash is computed on LF-normalized content
      tag = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "set", "tag" => tag, "content" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result

      written = File.read!(Path.join(cwd, "test.txt"))
      assert written =~ "\r\n"
      assert written =~ "BBB"
    end

    test "preserves UTF-8 BOM", %{cwd: cwd} do
      bom = <<0xEF, 0xBB, 0xBF>>
      content = bom <> "aaa\nbbb\nccc"
      write_test_file(cwd, "test.txt", content)
      tag = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "set", "tag" => tag, "content" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result

      written = File.read!(Path.join(cwd, "test.txt"))
      assert <<0xEF, 0xBB, 0xBF, _rest::binary>> = written
    end
  end

  # ============================================================================
  # replaceText Operation
  # ============================================================================

  describe "replaceText operation" do
    test "executes replaceText with first occurrence", %{cwd: cwd} do
      write_test_file(cwd, "rt.txt", "foo bar\nfoo baz")

      params = %{
        "path" => "rt.txt",
        "edits" => [
          %{"op" => "replaceText", "old_text" => "foo", "new_text" => "hello"}
        ]
      }

      result = HashlineEdit.execute("call1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert hd(result.content).text =~ "Applied 1 hashline edit"

      assert File.read!(Path.join(cwd, "rt.txt")) == "hello bar\nfoo baz"
    end

    test "executes replaceText with all occurrences", %{cwd: cwd} do
      write_test_file(cwd, "rt_all.txt", "foo bar\nfoo baz")

      params = %{
        "path" => "rt_all.txt",
        "edits" => [
          %{"op" => "replaceText", "old_text" => "foo", "new_text" => "hello", "all" => true}
        ]
      }

      result = HashlineEdit.execute("call2", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "rt_all.txt")) == "hello bar\nhello baz"
    end

    test "parse_edits handles replaceText" do
      raw = [%{"op" => "replaceText", "old_text" => "find", "new_text" => "replace", "all" => true}]
      {:ok, edits} = HashlineEdit.parse_edits(raw)
      assert length(edits) == 1
      [edit] = edits
      assert edit.op == :replace_text
      assert edit.old_text == "find"
      assert edit.new_text == "replace"
      assert edit.all == true
    end

    test "parse_edits returns error for empty old_text" do
      raw = [%{"op" => "replaceText", "old_text" => "", "new_text" => "replace"}]
      assert {:error, _} = HashlineEdit.parse_edits(raw)
    end
  end
end
