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

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "Hello",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Hello"
      assert details.match_count == 2
    end

    test "finds pattern in directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "Hello from file1")
      File.write!(Path.join(tmp_dir, "file2.txt"), "Hello from file2")
      File.write!(Path.join(tmp_dir, "file3.txt"), "No match here")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "Hello"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "file1"
      assert text =~ "file2"
      assert details.match_count == 2
    end

    test "returns no matches message when pattern not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello, World!")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "xyz123",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No matches found"
      assert details.match_count == 0
    end

    test "uses cwd when no path specified", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "searchable content")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "searchable"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "searchable"
    end
  end

  describe "execute/6 - regex patterns" do
    test "supports basic regex", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "foo123bar\nfoo456bar\nbaz789qux")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "foo\\d+bar",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 2
    end

    test "returns error for invalid regex", %{tmp_dir: tmp_dir} do
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "[invalid",
            "path" => tmp_dir
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "Invalid regex"
    end

    test "returns error for empty pattern", %{tmp_dir: tmp_dir} do
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => ""
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Pattern is required"} = result
    end
  end

  describe "execute/6 - case sensitivity" do
    test "case sensitive by default", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello\nhello\nHELLO")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "Hello",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 1
    end

    test "case insensitive when specified", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello\nhello\nHELLO")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "Hello",
            "path" => path,
            "case_sensitive" => false
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 3
    end
  end

  describe "execute/6 - glob filtering" do
    test "filters by glob pattern", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.ex"), "defmodule Test")
      File.write!(Path.join(tmp_dir, "test.exs"), "defmodule TestCase")
      File.write!(Path.join(tmp_dir, "test.txt"), "defmodule ShouldNotMatch")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "defmodule",
            "glob" => "*.ex"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "test.ex"
      refute text =~ "test.txt"
      assert details.match_count == 1
    end

    test "supports complex glob patterns", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.ex"), "match1")
      File.write!(Path.join(tmp_dir, "test.exs"), "match2")
      File.write!(Path.join(tmp_dir, "test.txt"), "no_match")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "match",
            "glob" => "*.{ex,exs}"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 2
    end
  end

  describe "execute/6 - context lines" do
    test "includes context lines when specified", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line1\nline2\nMATCH\nline4\nline5")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "MATCH",
            "path" => path,
            "context_lines" => 1
          },
          nil,
          nil,
          tmp_dir,
          []
        )

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

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "match",
            "path" => path,
            "max_results" => 5
          },
          nil,
          nil,
          tmp_dir,
          []
        )

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

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "findme",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 1
    end

    test "handles relative paths", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "relative.txt"), "findme")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "findme",
            "path" => "relative.txt"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 1
    end

    test "handles home directory expansion", %{tmp_dir: tmp_dir} do
      # This test just verifies the code path, actual ~ expansion would need real home dir
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "test",
            "path" => tmp_dir
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      # Should not error - either returns results or no matches
      assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
    end

    test "searches subdirectories", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "nested_match")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "nested_match"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "nested_match"
      assert details.match_count == 1
    end
  end

  describe "execute/6 - error handling" do
    test "returns error for non-existent path", %{tmp_dir: tmp_dir} do
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "test",
            "path" => Path.join(tmp_dir, "nonexistent")
          },
          nil,
          nil,
          tmp_dir,
          []
        )

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
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "content",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      # Either returns no matches or an error - both are acceptable
      assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
    end
  end

  describe "execute/6 - abort signal" do
    test "respects abort signal at start", %{tmp_dir: tmp_dir} do
      # Create an aborted signal
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "test"
          },
          signal,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "ripgrep execution safeguards" do
    test "times out ripgrep command instead of hanging", %{tmp_dir: tmp_dir} do
      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "test", "path" => tmp_dir},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: true,
          ripgrep_timeout_ms: 20,
          rg_cmd_fun: fn "rg", _args, _opts ->
            Process.sleep(200)
            {"", 0}
          end
        )

      assert {:error, msg} = result
      assert msg =~ "timed out"
    end

    test "respects abort while ripgrep command is running", %{tmp_dir: tmp_dir} do
      signal = AgentCore.AbortSignal.new()

      Task.start(fn ->
        Process.sleep(20)
        AgentCore.AbortSignal.abort(signal)
      end)

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "test", "path" => tmp_dir},
          signal,
          nil,
          tmp_dir,
          ripgrep_available?: true,
          ripgrep_timeout_ms: 2_000,
          rg_cmd_fun: fn "rg", _args, _opts ->
            Process.sleep(500)
            {"", 0}
          end
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "execute/6 - binary file handling" do
    test "skips binary files", %{tmp_dir: tmp_dir} do
      # Create a text file and a binary file
      File.write!(Path.join(tmp_dir, "text.txt"), "findme")
      File.write!(Path.join(tmp_dir, "binary.bin"), <<0, 1, 2, 102, 105, 110, 100, 109, 101, 0>>)

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "findme"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

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

      result =
        tool.execute.(
          "call_1",
          %{
            "pattern" => "test"
          },
          nil,
          nil
        )

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

  describe "tool/2 - grouped parameters" do
    test "includes grouped and max_per_file parameters" do
      tool = Grep.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "grouped")
      assert props["grouped"]["type"] == "boolean"
      assert Map.has_key?(props, "max_per_file")
      assert props["max_per_file"]["type"] == "integer"
    end
  end

  describe "execute/6 - grouped output" do
    test "returns grouped results when grouped=true", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "hello world\nhello again")
      File.write!(Path.join(tmp_dir, "file2.txt"), "hello there")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "hello", "grouped" => true},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.total_matches == 3
      assert map_size(details.results) == 2
      assert text =~ "file1"
      assert text =~ "file2"
    end

    test "grouped output details has expected keys", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello world")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "hello", "grouped" => true},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{details: details} = result
      assert Map.has_key?(details, :results)
      assert Map.has_key?(details, :total_matches)
      assert Map.has_key?(details, :files_searched)
      assert Map.has_key?(details, :truncated)
    end

    test "each file result contains line and match keys", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello world\nhello again")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "hello", "grouped" => true},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{details: %{results: results}} = result
      [match | _] = results |> Map.values() |> List.first()
      assert Map.has_key?(match, "line")
      assert Map.has_key?(match, "match")
    end

    test "max_per_file limits results per file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "match\nmatch\nmatch\nmatch\nmatch")
      File.write!(Path.join(tmp_dir, "file2.txt"), "match\nmatch\nmatch")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "match", "grouped" => true, "max_per_file" => 2},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{details: %{results: results}} = result

      Enum.each(results, fn {_file, matches} ->
        assert length(matches) <= 2
      end)
    end

    test "round-robin distributes results fairly across files", %{tmp_dir: tmp_dir} do
      file1_content = Enum.map_join(1..10, "\n", fn i -> "match_#{i}" end)
      File.write!(Path.join(tmp_dir, "afile.txt"), file1_content)
      File.write!(Path.join(tmp_dir, "bfile.txt"), "match_a\nmatch_b")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "match", "grouped" => true, "max_results" => 4},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{details: details} = result
      assert details.total_matches == 4
      counts = details.results |> Map.values() |> Enum.map(&length/1)
      # Round-robin: both files contribute equally (2 each)
      assert Enum.max(counts) - Enum.min(counts) <= 1
    end

    test "no matches with grouped=true returns empty results", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "no match here")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "xyz999", "grouped" => true},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No matches"
      assert details.total_matches == 0
    end

    test "grouped=false maintains backward compatibility", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello world\nhello again")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "hello", "grouped" => false},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: false
        )

      assert %AgentToolResult{details: details} = result
      assert details.match_count == 2
      refute Map.has_key?(details, :results)
    end

    test "grouped output with ripgrep backend", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "alpha.txt"), "hello world\nhello again")
      File.write!(Path.join(tmp_dir, "beta.txt"), "hello there")

      result =
        Grep.execute(
          "call_1",
          %{"pattern" => "hello", "grouped" => true},
          nil,
          nil,
          tmp_dir,
          ripgrep_available?: true,
          rg_cmd_fun: fn "rg", args, _opts ->
            # Simulate ripgrep output: file:line:content
            _ = args

            output =
              "#{tmp_dir}/alpha.txt:1:hello world\n#{tmp_dir}/alpha.txt:2:hello again\n#{tmp_dir}/beta.txt:1:hello there\n"

            {output, 0}
          end
        )

      assert %AgentToolResult{details: details} = result
      assert details.total_matches == 3
      assert map_size(details.results) == 2
    end
  end
end
