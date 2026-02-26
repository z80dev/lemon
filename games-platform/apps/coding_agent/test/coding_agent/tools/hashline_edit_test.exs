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
    hash = Hashline.compute_line_hash(line, content)
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

    test "schema has replace, append, prepend ops", %{cwd: cwd} do
      tool = HashlineEdit.tool(cwd)
      op_enum = tool.parameters["properties"]["edits"]["items"]["properties"]["op"]["enum"]
      assert op_enum == ["replace", "append", "prepend"]
    end
  end

  # ============================================================================
  # Parameter Validation
  # ============================================================================

  describe "parameter validation" do
    test "rejects missing path", %{cwd: cwd} do
      result = HashlineEdit.execute("call-1", %{"edits" => [%{"op" => "replace"}]}, nil, nil, cwd, [])
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
  # Replace Operation (Single Line)
  # ============================================================================

  describe "replace single line" do
    test "replaces a single line", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      pos = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "lines" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nBBB\nccc"
    end

    test "reports noop when content unchanged", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      pos = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "lines" => ["bbb"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.noop_edits != nil
    end

    test "fails on stale hash", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => "2#ZZ", "lines" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, msg} = result
      assert msg =~ "changed since last read"
    end

    test "expands a single line to multiple", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      pos = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "lines" => ["x", "y", "z"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nx\ny\nz\nccc"
    end
  end

  # ============================================================================
  # Replace Operation (Range)
  # ============================================================================

  describe "replace range" do
    test "replaces a range of lines", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc\nddd")
      pos = make_tag(2, "bbb")
      end_tag = make_tag(3, "ccc")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "end" => end_tag, "lines" => ["XXX"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nXXX\nddd"
    end

    test "deletes a range when lines is empty", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc\nddd")
      pos = make_tag(2, "bbb")
      end_tag = make_tag(3, "ccc")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "end" => end_tag, "lines" => []}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nddd"
    end
  end

  # ============================================================================
  # Append Operation
  # ============================================================================

  describe "append operation" do
    test "inserts after a line", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc")
      pos = make_tag(1, "aaa")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "append", "pos" => pos, "lines" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nNEW\nbbb\nccc"
    end

    test "appends at EOF without anchor", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "append", "lines" => ["NEW"]}]
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
      pos = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "prepend", "pos" => pos, "lines" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "aaa\nNEW\nbbb\nccc"
    end

    test "prepends at BOF without anchor", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "prepend", "lines" => ["NEW"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result
      assert File.read!(Path.join(cwd, "test.txt")) == "NEW\naaa\nbbb"
    end
  end

  # ============================================================================
  # Multiple Edits
  # ============================================================================

  describe "multiple edits" do
    test "applies multiple non-overlapping edits", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\nbbb\nccc\nddd\neee")
      pos2 = make_tag(2, "bbb")
      pos4 = make_tag(4, "ddd")

      params = %{
        "path" => "test.txt",
        "edits" => [
          %{"op" => "replace", "pos" => pos2, "lines" => ["BBB"]},
          %{"op" => "replace", "pos" => pos4, "lines" => ["DDD"]}
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
        "edits" => [%{"op" => "replace", "pos" => "1#ZZ", "lines" => ["x"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, "File not found: nonexistent.txt"} = result
    end

    test "returns error for invalid op", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "hello")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "delete_all", "lines" => []}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, "Unknown edit operation: delete_all"} = result
    end

    test "returns error for missing pos in replace op", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "hello")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "lines" => ["x"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert {:error, msg} = result
      assert msg =~ "Missing required field 'pos'"
    end
  end

  # ============================================================================
  # parse_edits/1
  # ============================================================================

  describe "parse_edits/1" do
    test "parses single-line replace edit" do
      pos = make_tag(1, "hello")
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "replace", "pos" => pos, "lines" => ["world"]}])
      assert edit.op == :replace
      assert edit.pos.line == 1
      assert edit.lines == ["world"]
      refute Map.has_key?(edit, :end)
    end

    test "parses range replace edit" do
      pos = make_tag(1, "a")
      end_tag = make_tag(3, "c")
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "replace", "pos" => pos, "end" => end_tag, "lines" => ["x"]}])
      assert edit.op == :replace
      assert edit.pos.line == 1
      assert edit.end.line == 3
    end

    test "parses append without anchor" do
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "append", "lines" => ["new"]}])
      assert edit.op == :append
      assert edit.pos == nil
    end

    test "parses append with anchor" do
      pos = make_tag(1, "hello")
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "append", "pos" => pos, "lines" => ["new"]}])
      assert edit.op == :append
      assert edit.pos.line == 1
    end

    test "parses prepend without anchor" do
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "prepend", "lines" => ["new"]}])
      assert edit.op == :prepend
      assert edit.pos == nil
    end

    test "parses prepend with anchor" do
      pos = make_tag(2, "world")
      {:ok, [edit]} = HashlineEdit.parse_edits([%{"op" => "prepend", "pos" => pos, "lines" => ["new"]}])
      assert edit.op == :prepend
      assert edit.pos.line == 2
    end

    test "returns error for unknown op" do
      assert {:error, _} = HashlineEdit.parse_edits([%{"op" => "unknown", "lines" => []}])
    end
  end

  # ============================================================================
  # BOM & Line Ending Preservation
  # ============================================================================

  describe "file format preservation" do
    test "preserves CRLF line endings", %{cwd: cwd} do
      write_test_file(cwd, "test.txt", "aaa\r\nbbb\r\nccc")
      # Hash is computed on LF-normalized content
      pos = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "lines" => ["BBB"]}]
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
      pos = make_tag(2, "bbb")

      params = %{
        "path" => "test.txt",
        "edits" => [%{"op" => "replace", "pos" => pos, "lines" => ["BBB"]}]
      }

      result = HashlineEdit.execute("call-1", params, nil, nil, cwd, [])
      assert %AgentCore.Types.AgentToolResult{} = result

      written = File.read!(Path.join(cwd, "test.txt"))
      assert <<0xEF, 0xBB, 0xBF, _rest::binary>> = written
    end
  end
end
