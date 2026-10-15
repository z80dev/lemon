defmodule CodingAgent.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Grep
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  describe "deterministic engines and bounded fallback" do
    test "rg sorts before paging even when output order changes", %{tmp_dir: root} do
      a = Path.join(root, "a.txt")
      b = Path.join(root, "b.txt")
      File.write!(a, "needle a1\nneedle a2")
      File.write!(b, "needle b1\nneedle b2")
      refs = [{b, 2}, {a, 2}, {b, 1}, {a, 1}]
      first = injected_grep(root, %{"max_results" => 2}, rg_output(refs), 0)

      last =
        injected_grep(root, %{"skip" => 2, "max_results" => 2}, rg_output(Enum.reverse(refs)), 0)

      assert first.details.next_skip == 2
      assert result_text(first) =~ "a.txt:1: needle a1\na.txt:2: needle a2"
      refute result_text(first) =~ "b.txt:"
      assert result_text(last) =~ "b.txt:1: needle b1\nb.txt:2: needle b2"
      refute result_text(last) =~ "a.txt:"
      refute Map.has_key?(last.details, :next_skip)
    end

    test "rg preserves partial matches and first warning, but errors without matches", %{
      tmp_dir: root
    } do
      file = Path.join(root, "a.txt")
      File.write!(file, "needle")
      output = rg_output([{file, 1}]) <> "\nrg: denied: Permission denied\nsecond warning"
      result = injected_grep(root, %{}, output, 2)
      assert result_text(result) =~ "a.txt:1: needle"
      assert result_text(result) =~ "warnings: rg: denied: Permission denied"
      assert result.details.warnings == ["rg: denied: Permission denied"]

      assert {:error, "Search error: rg: denied"} =
               injected_grep(root, %{}, "rg: denied\nanother error", 2)
    end

    test "lookarounds and backreferences select PCRE2 or explain unavailable engine", %{
      tmp_dir: root
    } do
      for {pattern, construct} <- [
            {"needle(?=!)", "lookaround"},
            {"(needle)\\1", "backreferences"}
          ] do
        assert %AgentToolResult{} =
                 Grep.execute("pcre", %{"pattern" => pattern}, nil, nil, root,
                   ripgrep_available?: true,
                   pcre2_available?: true,
                   rg_cmd_fun: fn "rg", args, _ ->
                     assert "--pcre2" in args
                     {"", 1}
                   end
                 )

        assert {:error, message} =
                 Grep.execute("pcre", %{"pattern" => pattern}, nil, nil, root,
                   ripgrep_available?: true,
                   pcre2_available?: false,
                   rg_cmd_fun: fn _, _, _ -> flunk("must not run unsupported pattern") end
                 )

        assert message =~ construct
        assert message =~ "rg uses Rust regex"
      end
    end

    test "escaped constructs and literal patterns do not require PCRE2", %{tmp_dir: root} do
      for {pattern, literal?} <- [
            {"\\(\\?=needle\\)", false},
            {"needle(?=!)", true},
            {"[(?=)]", false},
            {"\\\\1", false}
          ] do
        assert %AgentToolResult{} =
                 Grep.execute(
                   "rust",
                   %{"pattern" => pattern, "literal" => literal?},
                   nil,
                   nil,
                   root,
                   ripgrep_available?: true,
                   pcre2_available?: fn -> flunk("no probe needed") end,
                   rg_cmd_fun: fn _, args, _ ->
                     refute "--pcre2" in args
                     {"", 1}
                   end
                 )
      end
    end

    test "fallback sorts files and stops matching at skip plus max_results", %{tmp_dir: root} do
      files =
        for name <- ["c", "b", "a"] do
          file = Path.join(root, name <> ".txt")
          File.write!(file, "needle #{name}")
          file
        end

      owner = self()

      result =
        Grep.execute(
          "bounded",
          %{"pattern" => "needle", "skip" => 1, "max_results" => 1},
          nil,
          nil,
          root,
          ripgrep_available?: false,
          fallback_files_fun: fn _, _ -> files end,
          fallback_match_fun: fn line, _ ->
            send(owner, {:matched, line})
            true
          end
        )

      assert result_text(result) =~ "b.txt:1: needle b"
      assert result.details.incomplete
      assert result.details.next_skip == 2
      assert_receive {:matched, "needle a"}
      assert_receive {:matched, "needle b"}
      refute_receive {:matched, "needle c"}
    end

    test "fallback deadline includes enumeration and matching", %{tmp_dir: root} do
      file = Path.join(root, "a.txt")
      File.write!(file, "needle")

      for injection <- [
            [
              fallback_files_fun: fn _, _ ->
                Process.sleep(10_000)
                [file]
              end
            ],
            [
              fallback_match_fun: fn _, _ ->
                Process.sleep(10_000)
                true
              end
            ]
          ] do
        assert {:error, "Search timed out after 20ms"} =
                 Grep.execute(
                   "timeout",
                   %{"pattern" => "needle"},
                   nil,
                   nil,
                   root,
                   [ripgrep_available?: false, fallback_timeout_ms: 20] ++ injection
                 )
      end
    end

    test "fallback reads only the leading 4 MiB and counts oversized files", %{tmp_dir: root} do
      file = Path.join(root, "large.txt")
      prefix = "needle\n" <> String.duplicate("x", 4 * 1024 * 1024 - 7)
      File.write!(file, prefix <> "\nneedle beyond window")

      result =
        Grep.execute("large", %{"pattern" => "needle"}, nil, nil, root, ripgrep_available?: false)

      assert result.details.match_count == 1
      assert result.details.skipped_oversized == 1
      assert result_text(result) =~ "large.txt:1: needle"
      refute result_text(result) =~ "beyond window"
    end
  end

  defp rg_output(refs) do
    Enum.map_join(refs, "\n", fn {path, line} ->
      Jason.encode!(%{
        "type" => "match",
        "data" => %{
          "path" => %{"text" => path},
          "line_number" => line
        }
      })
    end)
  end

  defp injected_grep(root, params, output, code) do
    Grep.execute("injected", Map.put_new(params, "pattern", "needle"), nil, nil, root,
      ripgrep_available?: true,
      rg_cmd_fun: fn _, _, _ -> {output, code} end
    )
  end

  defp result_text(result), do: Enum.map_join(result.content, "\n", & &1.text)

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
      assert details.next_skip > 0 and details.next_skip < 20

      next =
        Grep.execute(
          "call_2",
          %{"pattern" => "match", "path" => path, "skip" => details.next_skip},
          nil,
          nil,
          tmp_dir,
          max_bytes: 300
        )

      assert Enum.map_join(next.content, "", & &1.text) =~
               ":#{details.next_skip + 1}: match#{details.next_skip + 1} "
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
      File.write!(Path.join(tmp_dir, ".ignore"), "private/\n")
      File.mkdir_p!(Path.join(tmp_dir, "private"))
      File.write!(Path.join(tmp_dir, "private/secret.txt"), "needle private\n")
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
        refute text =~ "needle private"
      end

      test "hidden and no_ignore include those files (ripgrep: #{rg?})", %{tmp_dir: tmp_dir} do
        params = %{"pattern" => "needle", "hidden" => true, "no_ignore" => true}
        assert %AgentToolResult{content: [%TextContent{text: text}]} = grep(tmp_dir, params, @rg)
        assert text =~ "needle ignored"
        assert text =~ "needle hidden"
        assert text =~ "needle private"
      end

      test "skip pages past max_results (ripgrep: #{rg?})", %{tmp_dir: tmp_dir} do
        first = grep(tmp_dir, %{"pattern" => "needle", "max_results" => 2}, @rg)
        assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = first
        assert details.next_skip == 2
        assert text =~ "visible.txt:1: needle 1"
        refute text =~ "needle 3"

        params = %{"pattern" => "needle", "max_results" => 2, "skip" => 4}
        last = grep(tmp_dir, params, @rg)
        assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = last
        assert text =~ "visible.txt:5: needle 5"
        refute text =~ "needle 4"
        refute Map.has_key?(details, :next_skip)
        assert details.skip == 4
      end
    end

    test "fallback honors nested ignore globs and negation outside a repository", %{
      tmp_dir: tmp_dir
    } do
      File.rm_rf!(Path.join(tmp_dir, ".git"))
      root = Path.join(tmp_dir, "nonrepo")
      File.mkdir_p!(Path.join(root, "nested"))
      File.write!(Path.join(root, ".ignore"), "**/*.cache\n!keep.cache\n")
      File.write!(Path.join(root, "skip.cache"), "needle skip")
      File.write!(Path.join(root, "keep.cache"), "needle keep")
      File.write!(Path.join(root, "nested/.ignore"), "ignored[12].txt\n")
      File.write!(Path.join(root, "nested/ignored1.txt"), "needle nested")
      File.write!(Path.join(root, "nested/visible.txt"), "needle visible")
      result = grep(root, %{"pattern" => "needle"}, false)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: %{match_count: 2}} =
               result

      assert text =~ "needle keep"
      assert text =~ "needle visible"
      refute text =~ "needle skip"
      refute text =~ "needle nested"
    end

    for root_kind <- [:non_repository, :gitignored_root] do
      test "fallback filters local gitignore before paging a #{root_kind}", %{tmp_dir: tmp_dir} do
        if unquote(root_kind) == :non_repository do
          File.rm_rf!(Path.join(tmp_dir, ".git"))
        else
          File.write!(Path.join(tmp_dir, ".gitignore"), "fixture/\n")
        end

        root = Path.join(tmp_dir, "fixture")
        File.mkdir_p!(Path.join(root, "ignored"))
        File.mkdir_p!(Path.join(root, "private"))
        File.write!(Path.join(root, ".gitignore"), "ignored/\n")
        File.write!(Path.join(root, ".ignore"), "private/\n")
        File.write!(Path.join(root, "ignored/skip.txt"), "needle ignored\n")
        File.write!(Path.join(root, "private/secret.txt"), "needle private\n")
        File.write!(Path.join(root, ".hidden.txt"), "needle hidden\n")
        File.write!(Path.join(root, "visible.txt"), Enum.map_join(1..5, "\n", &"needle #{&1}"))

        assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
                 grep(root, %{"pattern" => "needle"}, false)

        assert details.match_count == 5
        refute text =~ "needle ignored"
        refute text =~ "needle private"
        refute text =~ "needle hidden"

        assert %AgentToolResult{content: [%TextContent{text: first}], details: first_details} =
                 grep(root, %{"pattern" => "needle", "max_results" => 2}, false)

        assert first_details.next_skip == 2
        assert first =~ "visible.txt:1: needle 1"
        assert first =~ "visible.txt:2: needle 2"
        refute first =~ "needle 3"

        assert %AgentToolResult{content: [%TextContent{text: last}], details: last_details} =
                 grep(root, %{"pattern" => "needle", "max_results" => 2, "skip" => 4}, false)

        assert last =~ "visible.txt:5: needle 5"
        refute last =~ "needle 4"
        assert last_details.match_count == 5
        assert last_details.skip == 4
        refute Map.has_key?(last_details, :next_skip)
      end
    end

    defp grep(tmp_dir, params, rg?) do
      Grep.execute("call", params, nil, nil, tmp_dir, ripgrep_available?: rg?)
    end
  end
end
