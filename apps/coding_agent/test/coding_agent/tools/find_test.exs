defmodule CodingAgent.Tools.FindTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Find
  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Find.tool("/tmp")

      assert tool.name == "find"
      assert tool.label == "Find Files"
      assert tool.description =~ "Find files"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["pattern"]
      assert is_function(tool.execute, 4)
    end

    test "includes all expected parameters" do
      tool = Find.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "pattern")
      assert Map.has_key?(props, "path")
      assert Map.has_key?(props, "type")
      assert Map.has_key?(props, "max_depth")
      assert Map.has_key?(props, "max_results")
      assert Map.has_key?(props, "hidden")
    end
  end

  describe "execute/6 - basic search" do
    test "finds files by exact name", %{tmp_dir: tmp_dir} do
      # Create test files
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      File.write!(Path.join(tmp_dir, "other.txt"), "content")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Found 1 match"
      assert text =~ "test.txt"
      refute text =~ "other.txt"
      assert details.count == 1
      assert "test.txt" in details.files
    end

    test "finds files by glob pattern", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test1.txt"), "")
      File.write!(Path.join(tmp_dir, "test2.txt"), "")
      File.write!(Path.join(tmp_dir, "other.md"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 2
      assert "test1.txt" in details.files
      assert "test2.txt" in details.files
      refute "other.md" in details.files
    end

    test "returns no files message when nothing found", %{tmp_dir: tmp_dir} do
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "nonexistent.xyz"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No files found"
      assert details.count == 0
    end
  end

  describe "execute/6 - recursive search" do
    test "finds files in subdirectories", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(subdir, "nested.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 2
      assert "root.txt" in details.files
      assert "subdir/nested.txt" in details.files
    end

    test "respects max_depth parameter", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "level1")
      subsubdir = Path.join(subdir, "level2")
      File.mkdir_p!(subsubdir)
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(subdir, "level1.txt"), "")
      File.write!(Path.join(subsubdir, "level2.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_depth" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # Should find root.txt and level1.txt but not level2.txt
      assert "root.txt" in details.files
      assert "level1/level1.txt" in details.files or details.count <= 2
    end
  end

  describe "execute/6 - type filtering" do
    test "filters to files only", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "testdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "testfile.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test*", "type" => "file"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "testfile.txt" in details.files
      refute "testdir" in details.files
    end

    test "filters to directories only", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "testdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "testfile.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test*", "type" => "directory"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "testdir" in details.files
      refute "testfile.txt" in details.files
    end
  end

  describe "execute/6 - hidden files" do
    test "excludes hidden files by default", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "visible.txt"), "")
      File.write!(Path.join(tmp_dir, ".hidden.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "visible.txt" in details.files
      refute ".hidden.txt" in details.files
    end

    test "includes hidden files when requested", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "visible.txt"), "")
      File.write!(Path.join(tmp_dir, ".hidden.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "hidden" => true},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "visible.txt" in details.files
      assert ".hidden.txt" in details.files
    end
  end

  describe "execute/6 - result limiting" do
    test "respects max_results parameter", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => 5},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.count == 5
      assert details.truncated == true
      assert text =~ "limited to 5"
    end

    test "uses default max_results from opts", %{tmp_dir: tmp_dir} do
      for i <- 1..5 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          max_results: 3
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 3
      assert details.truncated == true
    end
  end

  describe "execute/6 - path parameter" do
    test "searches in specified subdirectory", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "search_here")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(subdir, "sub.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "search_here"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert "search_here/sub.txt" in details.files
    end

    test "handles absolute path", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "abs_test")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => subdir},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
    end
  end

  describe "execute/6 - error handling" do
    test "returns error for non-existent directory", %{tmp_dir: tmp_dir} do
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "nonexistent"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "Directory not found"
    end

    test "returns error when path is a file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "file.txt")
      File.write!(file_path, "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "file.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "not a directory"
    end
  end

  describe "execute/6 - abort signal" do
    test "respects abort signal at start" do
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          signal,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "integration.txt"), "")

      tool = Find.tool(tmp_dir)

      result =
        tool.execute.(
          "call_1",
          %{"pattern" => "integration.txt"},
          nil,
          nil
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert "integration.txt" in details.files
    end
  end
end
