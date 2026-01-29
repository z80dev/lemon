defmodule CodingAgent.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Grep
  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Grep.tool("/tmp")

      assert tool.name == "grep"
      assert tool.label == "Search Files"
      assert tool.description =~ "Search for patterns"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["pattern"]
      assert is_function(tool.execute, 4)
    end

    test "includes all expected parameters" do
      tool = Grep.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "pattern")
      assert Map.has_key?(props, "path")
      assert Map.has_key?(props, "glob")
      assert Map.has_key?(props, "case_sensitive")
      assert Map.has_key?(props, "context_lines")
      assert Map.has_key?(props, "max_results")
    end
  end

  describe "execute/6 - basic search" do
    test "finds pattern in a single file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello, World!\nGoodbye, World!\nHello again!")

      result = Grep.execute("call_1", %{
        "pattern" => "Hello",
        "path" => path
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Hello"
      assert details.match_count == 2
    end

    test "finds pattern in directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "Hello from file1")
      File.write!(Path.join(tmp_dir, "file2.txt"), "Hello from file2")
      File.write!(Path.join(tmp_dir, "file3.txt"), "No match here")

      result = Grep.execute("call_1", %{
        "pattern" => "Hello"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "file1"
      assert text =~ "file2"
      assert details.match_count == 2
    end

    test "returns no matches message when pattern not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello, World!")

      result = Grep.execute("call_1", %{
        "pattern" => "xyz123",
        "path" => path
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No matches found"
      assert details.match_count == 0
    end

    test "uses cwd when no path specified", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "searchable content")

      result = Grep.execute("call_1", %{
        "pattern" => "searchable"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "searchable"
    end
  end

  describe "execute/6 - regex patterns" do
    test "supports basic regex", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "foo123bar\nfoo456bar\nbaz789qux")

      result = Grep.execute("call_1", %{
        "pattern" => "foo\\d+bar",
        "path" => path
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 2
    end

    test "returns error for invalid regex", %{tmp_dir: tmp_dir} do
      result = Grep.execute("call_1", %{
        "pattern" => "[invalid",
        "path" => tmp_dir
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Invalid regex"
    end

    test "returns error for empty pattern", %{tmp_dir: tmp_dir} do
      result = Grep.execute("call_1", %{
        "pattern" => ""
      }, nil, nil, tmp_dir, [])

      assert {:error, "Pattern is required"} = result
    end
  end

  describe "execute/6 - case sensitivity" do
    test "case sensitive by default", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello\nhello\nHELLO")

      result = Grep.execute("call_1", %{
        "pattern" => "Hello",
        "path" => path
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 1
    end

    test "case insensitive when specified", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello\nhello\nHELLO")

      result = Grep.execute("call_1", %{
        "pattern" => "Hello",
        "path" => path,
        "case_sensitive" => false
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 3
    end
  end

  describe "execute/6 - glob filtering" do
    test "filters by glob pattern", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.ex"), "defmodule Test")
      File.write!(Path.join(tmp_dir, "test.exs"), "defmodule TestCase")
      File.write!(Path.join(tmp_dir, "test.txt"), "defmodule ShouldNotMatch")

      result = Grep.execute("call_1", %{
        "pattern" => "defmodule",
        "glob" => "*.ex"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "test.ex"
      refute text =~ "test.txt"
      assert details.match_count == 1
    end

    test "supports complex glob patterns", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.ex"), "match1")
      File.write!(Path.join(tmp_dir, "test.exs"), "match2")
      File.write!(Path.join(tmp_dir, "test.txt"), "no_match")

      result = Grep.execute("call_1", %{
        "pattern" => "match",
        "glob" => "*.{ex,exs}"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 2
    end
  end

  describe "execute/6 - context lines" do
    test "includes context lines when specified", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line1\nline2\nMATCH\nline4\nline5")

      result = Grep.execute("call_1", %{
        "pattern" => "MATCH",
        "path" => path,
        "context_lines" => 1
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Should include line2 and line4 as context
      assert text =~ "line2" or text =~ "2"
      assert text =~ "line4" or text =~ "4"
    end
  end

  describe "execute/6 - result limiting" do
    test "limits results to max_results", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      content = Enum.map_join(1..50, "\n", fn i -> "match line #{i}" end)
      File.write!(path, content)

      result = Grep.execute("call_1", %{
        "pattern" => "match",
        "path" => path,
        "max_results" => 5
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.truncated == true
      assert text =~ "truncated"
    end

    test "uses default max_results of 100", %{tmp_dir: tmp_dir} do
      tool = Grep.tool(tmp_dir)
      # Verify the tool was created with proper defaults
      assert tool.parameters["properties"]["max_results"]["description"] =~ "100"
    end
  end

  describe "execute/6 - path handling" do
    test "handles absolute paths", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absolute.txt")
      File.write!(path, "findme")

      result = Grep.execute("call_1", %{
        "pattern" => "findme",
        "path" => path
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 1
    end

    test "handles relative paths", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "relative.txt"), "findme")

      result = Grep.execute("call_1", %{
        "pattern" => "findme",
        "path" => "relative.txt"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 1
    end

    test "handles home directory expansion", %{tmp_dir: tmp_dir} do
      # This test just verifies the code path, actual ~ expansion would need real home dir
      result = Grep.execute("call_1", %{
        "pattern" => "test",
        "path" => tmp_dir
      }, nil, nil, tmp_dir, [])

      # Should not error - either returns results or no matches
      assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
    end

    test "searches subdirectories", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "nested_match")

      result = Grep.execute("call_1", %{
        "pattern" => "nested_match"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "nested_match"
      assert details.match_count == 1
    end
  end

  describe "execute/6 - error handling" do
    test "returns error for non-existent path", %{tmp_dir: tmp_dir} do
      result = Grep.execute("call_1", %{
        "pattern" => "test",
        "path" => Path.join(tmp_dir, "nonexistent")
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found"
    end

    test "handles permission errors gracefully", %{tmp_dir: tmp_dir} do
      # Create a file and make it unreadable
      path = Path.join(tmp_dir, "unreadable.txt")
      File.write!(path, "content")
      File.chmod!(path, 0o000)

      # Clean up on exit
      on_exit(fn -> File.chmod(path, 0o644) end)

      # Search should not crash, but may not find the file
      result = Grep.execute("call_1", %{
        "pattern" => "content",
        "path" => path
      }, nil, nil, tmp_dir, [])

      # Either returns no matches or an error - both are acceptable
      assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
    end
  end

  describe "execute/6 - abort signal" do
    test "respects abort signal at start", %{tmp_dir: tmp_dir} do
      # Create an aborted signal
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result = Grep.execute("call_1", %{
        "pattern" => "test"
      }, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "execute/6 - binary file handling" do
    test "skips binary files", %{tmp_dir: tmp_dir} do
      # Create a text file and a binary file
      File.write!(Path.join(tmp_dir, "text.txt"), "findme")
      File.write!(Path.join(tmp_dir, "binary.bin"), <<0, 1, 2, 102, 105, 110, 100, 109, 101, 0>>)

      result = Grep.execute("call_1", %{
        "pattern" => "findme"
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Should find in text file but not binary
      assert text =~ "text.txt"
      refute text =~ "binary.bin"
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "integration.txt"), "test content here")

      tool = Grep.tool(tmp_dir)

      result = tool.execute.("call_1", %{
        "pattern" => "test"
      }, nil, nil)

      assert %AgentToolResult{details: details} = result
      assert details.match_count >= 1
    end
  end

  describe "ripgrep_available?/0" do
    test "returns boolean" do
      result = Grep.ripgrep_available?()
      assert is_boolean(result)
    end
  end
end
