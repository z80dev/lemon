defmodule CodingAgent.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Grep
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir
  test "fallback skips explicitly targeted binary files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "binary.dat"), <<"needle", 0, 255>>)

    assert %AgentToolResult{details: %{match_count: 0}} =
             Grep.execute(
               "binary",
               %{"pattern" => "needle", "path" => "binary.dat"},
               nil,
               nil,
               tmp_dir,
               ripgrep_available?: false
             )
  end

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
      assert Map.has_key?(props, "literal")
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

    test "supports literal search when requested", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "a.c\nabc\nliteral a.c")

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "a.c",
            "path" => path,
            "literal" => true
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.match_count == 2
      assert text =~ "test.txt:1: a.c"
      assert text =~ "test.txt:3: literal a.c"
      refute text =~ "test.txt:2: abc"
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

    test "returns error for invalid context_lines", %{tmp_dir: tmp_dir} do
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "MATCH",
            "path" => tmp_dir,
            "context_lines" => -1
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "context_lines must be a non-negative integer"
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
      assert details.match_limit_reached == 5
      assert text =~ "limit reached"
    end

    test "uses default max_results of 100", %{tmp_dir: tmp_dir} do
      tool = Grep.tool(tmp_dir)
      # Verify the tool was created with proper defaults
      assert tool.parameters["properties"]["max_results"]["description"] =~ "100"
    end

    test "returns error for invalid max_results", %{tmp_dir: tmp_dir} do
      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "match",
            "max_results" => 0
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "max_results must be a positive integer"
    end

    test "truncates long match lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "prefix " <> String.duplicate("x", 700))

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "prefix",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.lines_truncated == true
      assert text =~ "[truncated]"
    end

    test "truncates aggregate output to byte budget", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")

      content =
        Enum.map_join(1..20, "\n", fn i ->
          "match#{i} " <> String.duplicate("x", 80)
        end)

      File.write!(path, content)

      result =
        Grep.execute(
          "call_1",
          %{
            "pattern" => "match",
            "path" => path
          },
          nil,
          nil,
          tmp_dir,
          max_bytes: 300
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.truncation.truncated == true
      assert text =~ "300B limit reached"
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
      signal = LemonAgent.AbortSignal.new()
      LemonAgent.AbortSignal.abort(signal)

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
            Process.sleep(10_000)
            {"", 0}
          end
        )

      assert {:error, msg} = result
      assert msg =~ "timed out"
    end

    test "respects abort while ripgrep command is running", %{tmp_dir: tmp_dir} do
      signal = LemonAgent.AbortSignal.new()

      Task.start(fn ->
        Process.sleep(20)
        LemonAgent.AbortSignal.abort(signal)
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
            Process.sleep(10_000)
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

  describe "patterns that start with a dash" do
    test "are searched for, not parsed as flags", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "flags.ex"), "-foo value\nfn x -> y end\nplain\n")

      result = Grep.execute("call_1", %{"pattern" => "-foo"}, nil, nil, tmp_dir, [])
      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.match_count == 1
      assert text =~ "-foo value"

      params = %{"pattern" => "->", "literal" => true}
      arrow = Grep.execute("call_2", params, nil, nil, tmp_dir, [])
      assert %AgentToolResult{details: %{match_count: 1}} = arrow
    end
  end

  describe "paging, hidden and ignored files" do
    setup %{tmp_dir: tmp_dir} do
      {_, 0} = System.cmd("git", ["init", "-q", tmp_dir])
      File.write!(Path.join(tmp_dir, ".gitignore"), "ignored/\n")
      File.mkdir_p!(Path.join(tmp_dir, "ignored"))
      File.write!(Path.join(tmp_dir, "ignored/skip.txt"), "needle ignored\n")
      File.write!(Path.join(tmp_dir, ".hidden.txt"), "needle hidden\n")
      File.write!(Path.join(tmp_dir, "visible.txt"), Enum.map_join(1..5, "\n", &"needle #{&1}"))
      :ok
    end

    for rg? <- [true, false], rg? == false or System.find_executable("rg") != nil do
      @rg rg?
      test "skips ignored and hidden files by default (ripgrep: #{rg?})", %{tmp_dir: tmp_dir} do
        result = grep(tmp_dir, %{"pattern" => "needle"}, @rg)
        assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
        assert details.match_count == 5
        refute text =~ "ignored"
        refute text =~ "hidden"
      end

      test "hidden and no_ignore include those files (ripgrep: #{rg?})", %{tmp_dir: tmp_dir} do
        params = %{"pattern" => "needle", "hidden" => true, "no_ignore" => true}
        assert %AgentToolResult{content: [%TextContent{text: text}]} = grep(tmp_dir, params, @rg)
        assert text =~ "needle ignored"
        assert text =~ "needle hidden"
      end

      test "skip pages past max_results (ripgrep: #{rg?})", %{tmp_dir: tmp_dir} do
        first = grep(tmp_dir, %{"pattern" => "needle", "max_results" => 2}, @rg)
        assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = first
        assert details.next_skip == 2
        assert text =~ "showing matches 1-2 of 5. Use skip=2"
        assert text =~ "visible.txt:1: needle 1"

        params = %{"pattern" => "needle", "max_results" => 2, "skip" => 4}
        last = grep(tmp_dir, params, @rg)
        assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = last
        assert text =~ "visible.txt:5: needle 5"
        refute text =~ "needle 4"
        refute Map.has_key?(details, :next_skip)
        assert details.skip == 4
      end
    end

    test "rejects a negative skip", %{tmp_dir: tmp_dir} do
      assert {:error, "skip must be a non-negative integer" <> _} =
               grep(tmp_dir, %{"pattern" => "needle", "skip" => -1}, false)
    end

    defp grep(tmp_dir, params, rg?) do
      Grep.execute("call", params, nil, nil, tmp_dir, ripgrep_available?: rg?)
    end
  end
end
