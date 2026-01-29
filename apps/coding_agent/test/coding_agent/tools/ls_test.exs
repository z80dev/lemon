defmodule CodingAgent.Tools.LsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Ls
  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Ls.tool("/tmp")

      assert tool.name == "ls"
      assert tool.label == "List Directory"
      assert tool.description =~ "List directory contents"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == []
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/6 - basic listing" do
    test "lists current directory when no path specified", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "content")
      File.write!(Path.join(tmp_dir, "file2.txt"), "content")

      result = Ls.execute("call_1", %{}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "file1.txt"
      assert text =~ "file2.txt"
      assert text =~ "2 entries"
    end

    test "lists specified directory", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "content")

      result = Ls.execute("call_1", %{"path" => "subdir"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "nested.txt"
      assert text =~ "1 entries"
    end

    test "handles absolute paths", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "abs.txt"), "content")

      result = Ls.execute("call_1", %{"path" => tmp_dir}, nil, nil, "/", [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "abs.txt"
    end

    test "shows empty directory message", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty_dir)

      result = Ls.execute("call_1", %{"path" => "empty"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "(empty directory)"
    end
  end

  describe "execute/6 - hidden files" do
    test "excludes hidden files by default", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "content")
      File.write!(Path.join(tmp_dir, "visible.txt"), "content")

      result = Ls.execute("call_1", %{}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "visible.txt"
      refute text =~ ".hidden"
    end

    test "includes hidden files when all=true", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "content")
      File.write!(Path.join(tmp_dir, "visible.txt"), "content")

      result = Ls.execute("call_1", %{"all" => true}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "visible.txt"
      assert text =~ ".hidden"
    end
  end

  describe "execute/6 - long format" do
    test "shows metadata in long format", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "hello world")
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))

      result = Ls.execute("call_1", %{"long" => true}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Should have type indicators
      assert text =~ "d "
      assert text =~ "- "
      # Should have size
      assert text =~ "B"
      # Should have permissions
      assert text =~ "r"
    end

    test "formats file sizes correctly", %{tmp_dir: tmp_dir} do
      # Create files of different sizes
      File.write!(Path.join(tmp_dir, "small.txt"), String.duplicate("x", 100))
      File.write!(Path.join(tmp_dir, "medium.txt"), String.duplicate("x", 2048))

      result = Ls.execute("call_1", %{"long" => true}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "100B"
      assert text =~ "K"
    end
  end

  describe "execute/6 - recursive listing" do
    test "lists subdirectories recursively", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "root.txt"), "content")
      subdir = Path.join(tmp_dir, "level1")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "content")

      result = Ls.execute("call_1", %{"recursive" => true}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "root.txt"
      assert text =~ "level1"
      assert text =~ "nested.txt"
    end

    test "respects max_depth for recursive listing", %{tmp_dir: tmp_dir} do
      # Create nested structure
      level1 = Path.join(tmp_dir, "level1")
      level2 = Path.join(level1, "level2")
      level3 = Path.join(level2, "level3")
      File.mkdir_p!(level3)
      File.write!(Path.join(level1, "l1.txt"), "content")
      File.write!(Path.join(level2, "l2.txt"), "content")
      File.write!(Path.join(level3, "l3.txt"), "content")

      result = Ls.execute("call_1", %{"recursive" => true, "max_depth" => 1}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "level1"
      assert text =~ "l1.txt"
      # level2 directory should be listed but not its contents
      assert text =~ "level2"
      refute text =~ "l2.txt"
      refute text =~ "l3.txt"
    end
  end

  describe "execute/6 - max_entries limit" do
    test "truncates output when exceeding max_entries", %{tmp_dir: tmp_dir} do
      # Create more files than the limit
      for i <- 1..10 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "content")
      end

      result = Ls.execute("call_1", %{"max_entries" => 5}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Showing 5 of 10 entries"
      assert details.truncated == true
      assert details.total_entries == 10
      assert details.shown_entries == 5
    end

    test "uses default max_entries from opts", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "content")
      end

      result = Ls.execute("call_1", %{}, nil, nil, tmp_dir, max_entries: 3)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Showing 3 of 10 entries"
    end
  end

  describe "execute/6 - sorting" do
    test "sorts directories before files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "aaa_file.txt"), "content")
      File.mkdir_p!(Path.join(tmp_dir, "zzz_dir"))
      File.write!(Path.join(tmp_dir, "bbb_file.txt"), "content")
      File.mkdir_p!(Path.join(tmp_dir, "aaa_dir"))

      result = Ls.execute("call_1", %{}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      lines = String.split(text, "\n")
      # Find lines with entries (skip header)
      entry_lines = Enum.filter(lines, &String.starts_with?(&1, ["d ", "- "]))

      # First two should be directories, last two should be files
      assert Enum.at(entry_lines, 0) =~ "d "
      assert Enum.at(entry_lines, 1) =~ "d "
      assert Enum.at(entry_lines, 2) =~ "- "
      assert Enum.at(entry_lines, 3) =~ "- "
    end

    test "sorts alphabetically within type groups", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "zebra.txt"), "content")
      File.write!(Path.join(tmp_dir, "apple.txt"), "content")
      File.write!(Path.join(tmp_dir, "mango.txt"), "content")

      result = Ls.execute("call_1", %{}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      lines = String.split(text, "\n")
      entry_lines = Enum.filter(lines, &String.starts_with?(&1, "- "))

      assert Enum.at(entry_lines, 0) =~ "apple.txt"
      assert Enum.at(entry_lines, 1) =~ "mango.txt"
      assert Enum.at(entry_lines, 2) =~ "zebra.txt"
    end
  end

  describe "execute/6 - error handling" do
    test "returns error for non-existent directory", %{tmp_dir: tmp_dir} do
      result = Ls.execute("call_1", %{"path" => "nonexistent"}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Directory not found"
    end

    test "returns error when path is a file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")

      result = Ls.execute("call_1", %{"path" => "file.txt"}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Path is a file, not a directory"
    end
  end

  describe "execute/6 - path expansion" do
    test "expands home directory", %{tmp_dir: tmp_dir} do
      # This test will use the actual home directory
      home = Path.expand("~")

      # Only run if home exists and is readable
      if File.dir?(home) do
        result = Ls.execute("call_1", %{"path" => "~"}, nil, nil, tmp_dir, [])
        assert %AgentToolResult{} = result
      end
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "integration.txt"), "content")

      tool = Ls.tool(tmp_dir)

      result = tool.execute.("call_1", %{}, nil, nil)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "integration.txt"
    end
  end
end
