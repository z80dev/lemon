defmodule CodingAgent.Tools.GlobTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Glob
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  # ============================================================================
  # Tool Definition Tests
  # ============================================================================

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Glob.tool("/tmp")

      assert tool.name == "glob"
      assert tool.label == "Glob Files"
      assert tool.description =~ "Find files"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["pattern"]
      assert tool.parameters["properties"]["pattern"]["type"] == "string"
      assert tool.parameters["properties"]["path"]["type"] == "string"
      assert tool.parameters["properties"]["max_results"]["type"] == "integer"
      assert is_function(tool.execute, 4)
    end

    test "tool execute function can be invoked", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      tool = Glob.tool(tmp_dir)

      result = tool.execute.("call_1", %{"pattern" => "*.txt"}, nil, nil)

      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Basic Pattern Matching
  # ============================================================================

  describe "execute/6 - basic pattern matching" do
    test "finds files matching simple pattern", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "content")
      File.write!(Path.join(tmp_dir, "file2.txt"), "content")
      File.write!(Path.join(tmp_dir, "file3.ex"), "content")

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "file1.txt"
      assert text =~ "file2.txt"
      refute text =~ "file3.ex"
      assert details.count == 2
    end

    test "finds files matching wildcard pattern", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test_file.ex"), "content")
      File.write!(Path.join(tmp_dir, "other.ex"), "content")

      result = Glob.execute("call_1", %{"pattern" => "test*.ex"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "test_file.ex"
      refute text =~ "other.ex"
      assert details.count == 1
    end

    test "finds files in nested directories", %{tmp_dir: tmp_dir} do
      nested = Path.join(tmp_dir, "a/b/c")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "deep.txt"), "content")

      result = Glob.execute("call_1", %{"pattern" => "**/*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "deep.txt"
    end

    test "returns 'No files found' when no matches", %{tmp_dir: tmp_dir} do
      result = Glob.execute("call_1", %{"pattern" => "*.nonexistent"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No files found"
      assert details.count == 0
    end
  end

  # ============================================================================
  # Path Parameter
  # ============================================================================

  describe "execute/6 - path parameter" do
    test "searches in specified path", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "in_subdir.txt"), "content")
      File.write!(Path.join(tmp_dir, "in_root.txt"), "content")

      result =
        Glob.execute("call_1", %{"pattern" => "*.txt", "path" => "subdir"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "in_subdir.txt"
      refute text =~ "in_root.txt"
    end

    test "handles absolute path", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")

      result =
        Glob.execute("call_1", %{"pattern" => "*.txt", "path" => tmp_dir}, nil, nil, "/other", [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "file.txt"
    end

    test "expands home directory", %{tmp_dir: tmp_dir} do
      # Just verify it doesn't crash with ~ - actual result depends on home dir contents
      result =
        Glob.execute(
          "call_1",
          %{"pattern" => "*.nonexistent", "path" => "~"},
          nil,
          nil,
          tmp_dir,
          []
        )

      # Either succeeds or returns error - both are valid behaviors
      case result do
        %AgentToolResult{} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # Result Limiting
  # ============================================================================

  describe "execute/6 - result limiting" do
    test "limits results to max_results", %{tmp_dir: tmp_dir} do
      for i <- 1..20 do
        File.write!(
          Path.join(tmp_dir, "file#{String.pad_leading("#{i}", 2, "0")}.txt"),
          "content"
        )
      end

      result =
        Glob.execute("call_1", %{"pattern" => "*.txt", "max_results" => 5}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.count == 5
      assert details.truncated == true
      assert text =~ "truncated"
    end

    test "uses default max_results when not specified", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.truncated == false
    end

    test "respects max_results from opts", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "content")
      end

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, max_results: 3)

      assert %AgentToolResult{details: details} = result
      assert details.count == 3
      assert details.truncated == true
    end
  end

  # ============================================================================
  # Sorting
  # ============================================================================

  describe "execute/6 - result sorting" do
    test "sorts results by modification time descending", %{tmp_dir: tmp_dir} do
      # Create files with different mtimes
      old_file = Path.join(tmp_dir, "old.txt")
      new_file = Path.join(tmp_dir, "new.txt")

      File.write!(old_file, "old content")
      Process.sleep(100)
      File.write!(new_file, "new content")

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      lines = String.split(text, "\n", trim: true)

      # Most recently modified should be first
      assert hd(lines) =~ "new.txt"
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "execute/6 - error handling" do
    test "returns error when pattern is empty" do
      result = Glob.execute("call_1", %{"pattern" => ""}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "Pattern is required"
    end

    test "returns error when pattern is missing" do
      result = Glob.execute("call_1", %{}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "Pattern is required"
    end

    test "returns error when max_results is invalid" do
      result =
        Glob.execute("call_1", %{"pattern" => "*.txt", "max_results" => 0}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "max_results must be a positive integer"
    end

    test "returns error when max_results is not an integer" do
      result =
        Glob.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => 1.5},
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, msg} = result
      assert msg =~ "max_results must be a positive integer"
    end
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  describe "execute/6 - abort signal" do
    test "returns error when signal is already aborted at start" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, signal, nil, "/tmp", [])

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds normally when signal is not aborted", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")
      signal = AbortSignal.new()

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, signal, nil, tmp_dir, [])

      AbortSignal.clear(signal)

      assert %AgentToolResult{} = result
    end

    test "proceeds normally when signal is nil", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # File Filtering
  # ============================================================================

  describe "execute/6 - file filtering" do
    test "only returns regular files, not directories", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")
      File.mkdir_p!(Path.join(tmp_dir, "dir.txt"))

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.count == 1
      assert text =~ "file.txt"
      refute text =~ "dir.txt" or text =~ "No files found"
    end
  end

  # ============================================================================
  # Result Details
  # ============================================================================

  describe "execute/6 - result details" do
    test "includes complete details", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")

      result = Glob.execute("call_1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert details.truncated == false
      assert details.base_path == tmp_dir
    end
  end
end
